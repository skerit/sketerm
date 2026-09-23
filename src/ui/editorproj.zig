//! Project-scoped services for the editor face: root resolution, the
//! project-wide search/replace panel, and the git gutter refresh.
//!
//! Everything here is a DAEMON round trip on a worker thread, handed
//! back through a `g_idle_add` fenced by `EditorView.Fence` — exactly
//! the shape `editorview.zig`'s load/save/probe jobs already have. The
//! GUI never touches the disk and never runs a process: the git
//! gutter is the daemon's `git_diff` job, which runs git on the
//! file's own host and hands back parsed per-line runs.
//!
//! The models these jobs fill are GTK-free and unit-tested:
//! `editor/project.zig`, `editor/psearch.zig`, `editor/gitdiff.zig`.
//!
//! ## What "the project" means here
//!
//! Each tab resolves at most one project (see editor/project.zig). The
//! search panel and the git gutter both work on the ACTIVE tab's
//! project, so a face holding files from three repositories does the
//! right thing without ever asking the user which one is meant. A tab
//! with no project simply has both features switched off, and no job is
//! ever started for it.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const ev = @import("editorview.zig");
const EditorView = ev.EditorView;
const ETab = ev.ETab;
const Fence = ev.Fence;
const project_mod = @import("../editor/project.zig");
const findbar = @import("findbar.zig");
const psearch = @import("../editor/psearch.zig");
const gitdiff = @import("../editor/gitdiff.zig");
const search = @import("../editor/search.zig");
const fsdrive = @import("../ipc/fsdrive.zig");
const paths = @import("../filebrowser/paths.zig");
const editorio = @import("editorio.zig");

/// Worker threads allocate from the C allocator, like every other
/// editor IO job: the models they build are MOVED onto the main thread
/// wholesale, so both sides must agree on the allocator.
const wa = std.heap.c_allocator;

/// Bound on one project-wide job. A search over a big tree is minutes
/// of daemon work at worst; past this the user has asked the wrong
/// question.
const JOB_TIMEOUT_MS: i64 = 120_000;

// ======================================================================
// Project root resolution
// ======================================================================

/// One directory listing, cached so `project.discover`'s marker probes
/// cost one round trip per ANCESTOR rather than one per marker.
const DirCache = struct {
    fs: *fsdrive.Fs,
    arena: std.heap.ArenaAllocator,
    dirs: std.ArrayList(Entry) = .empty,
    /// A listing failed in TRANSPORT: the discovery answer means nothing
    /// and the job retries on a fresh connection.
    transport_err: ?anyerror = null,

    const Entry = struct { dir: []u8, names: [][]u8 };

    fn deinit(self: *DirCache) void {
        self.arena.deinit();
        self.dirs.deinit(wa);
    }

    fn namesOf(self: *DirCache, dir: []const u8) ?[][]u8 {
        for (self.dirs.items) |e| {
            if (std.mem.eql(u8, e.dir, dir)) return e.names;
        }
        const a = self.arena.allocator();
        var listing = self.fs.list(dir) catch |err| {
            if (editorio.isTransportError(err)) self.transport_err = err;
            // A directory we cannot list holds no markers we can see.
            const empty = a.dupe(u8, dir) catch return null;
            self.dirs.append(wa, .{ .dir = empty, .names = &.{} }) catch return null;
            return &.{};
        };
        defer listing.deinit();
        var names: std.ArrayList([]u8) = .empty;
        for (listing.entries) |entry| {
            const nm = a.dupe(u8, entry.name) catch continue;
            names.append(a, nm) catch continue;
        }
        const owned = names.toOwnedSlice(a) catch return null;
        const key = a.dupe(u8, dir) catch return null;
        self.dirs.append(wa, .{ .dir = key, .names = owned }) catch return null;
        return owned;
    }

    fn exists(ctx: ?*anyopaque, dir: []const u8, name: []const u8) bool {
        const self = cast.userData(DirCache, ctx);
        const names = self.namesOf(dir) orelse return false;
        for (names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};

const ProjJob = struct {
    fence: *Fence,
    tab_id: u64,
    gen: u64,
    spec: []u8,
    markers: []u8,
    found: bool = false,
    root_buf: [4096]u8 = undefined,
    root_len: usize = 0,
    marker_buf: [96]u8 = undefined,
    marker_len: usize = 0,

    fn destroy(self: *ProjJob) void {
        wa.free(self.spec);
        wa.free(self.markers);
        self.fence.unref();
        wa.destroy(self);
    }

    fn run(self: *ProjJob, fs: *fsdrive.Fs) !void {
        var cache = DirCache{ .fs = fs, .arena = std.heap.ArenaAllocator.init(wa) };
        defer cache.deinit();
        const found = project_mod.discover(self.spec, self.markers, DirCache.exists, &cache);
        if (cache.transport_err) |err| return err;
        const f = found orelse return;
        self.found = true;
        self.root_len = @min(f.root.len, self.root_buf.len);
        @memcpy(self.root_buf[0..self.root_len], f.root[0..self.root_len]);
        self.marker_len = @min(f.marker.len, self.marker_buf.len);
        @memcpy(self.marker_buf[0..self.marker_len], f.marker[0..self.marker_len]);
    }
};

/// Resolve `tab`'s project in the background. Idempotent and cheap to
/// call: a tab with no spec, or one whose resolution is already in
/// flight, returns immediately.
pub fn resolveProject(view: *EditorView, tab: *ETab) void {
    const spec = tab.spec orelse return;
    if (tab.proj_gen != 0) return;
    const job = wa.create(ProjJob) catch return;
    const spec_copy = wa.dupe(u8, spec) catch {
        wa.destroy(job);
        return;
    };
    const markers = wa.dupe(u8, view.projects.markers) catch {
        wa.free(spec_copy);
        wa.destroy(job);
        return;
    };
    view.next_job_gen += 1;
    tab.proj_gen = view.next_job_gen;
    view.fence.ref();
    job.* = .{
        .fence = view.fence,
        .tab_id = tab.id,
        .gen = tab.proj_gen,
        .spec = spec_copy,
        .markers = markers,
    };
    const th = c.g_thread_new("sketerm-proj", @ptrCast(&projThread), @ptrCast(job));
    if (th == null) {
        tab.proj_gen = 0;
        job.destroy();
        return;
    }
    c.g_thread_unref(th);
}

fn projThread(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const job = cast.userData(ProjJob, data);
    editorio.withFs(paths.parseSpec(job.spec).host, job, ProjJob.run) catch {};
    _ = c.g_idle_add(@ptrCast(&projIdle), @ptrCast(job));
    return null;
}

fn projIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(ProjJob, user);
    defer job.destroy();
    const view = job.fence.viewIfAlive() orelse return 0;
    const tab = view.findTabById(job.tab_id) orelse return 0;
    if (tab.proj_gen != job.gen) return 0;
    tab.proj_gen = 0;
    if (!job.found) return 0;
    // The resolution ran against a HOST; re-acquire through the view's
    // set so the (host, root) dedupe and the refcount are the main
    // thread's business only.
    const loc = paths.parseSpec(tab.spec orelse return 0);
    var fixed = FixedRoot{
        .root = job.root_buf[0..job.root_len],
        .marker = job.marker_buf[0..job.marker_len],
        .host = loc.host orelse "",
    };
    view.projects.release(tab.project);
    tab.project = view.projects.acquire(tab.spec.?, FixedRoot.exists, &fixed);
    // The layout's recorded root has served its purpose.
    if (tab.restored_project) |rp| {
        view.allocator.free(rp);
        tab.restored_project = null;
    }
    view.updateStatus();
    if (view.git_gutter) refreshGit(view, tab);
    return 0;
}

/// Replays the worker's answer through `project.Set.acquire` without a
/// second filesystem walk: the predicate says "yes" exactly once, for
/// the directory and marker the worker found.
const FixedRoot = struct {
    root: []const u8,
    marker: []const u8,
    host: []const u8,

    fn exists(ctx: ?*anyopaque, dir: []const u8, name: []const u8) bool {
        const self = cast.userData(FixedRoot, ctx);
        return std.mem.eql(u8, dir, self.root) and std.mem.eql(u8, name, self.marker);
    }
};

// ======================================================================
// Git gutter
// ======================================================================

const GitJob = struct {
    fence: *Fence,
    tab_id: u64,
    gen: u64,
    spec: []u8,
    /// Per-line marks, already folded into runs by the daemon. Owned.
    runs: []fsdrive.gitdiff.Run = &.{},
    /// The daemon's answer to "is there anything to compare against?".
    repo: bool = false,
    tracked: bool = false,
    initial: bool = false,
    ok: bool = false,

    fn destroy(self: *GitJob) void {
        wa.free(self.spec);
        if (self.runs.len > 0) wa.free(self.runs);
        self.fence.unref();
        wa.destroy(self);
    }

    /// One daemon job on the FILE'S host: it finds the repository from
    /// the file's own directory, runs the diff there and parses it
    /// there. Any daemon-side failure (including a daemon whose build
    /// has no such verb) leaves the tab saying it does not know, never
    /// "clean"; only a transport failure is returned, for the retry.
    fn run(self: *GitJob, fs: *fsdrive.Fs) !void {
        const res = fs.gitDiff(wa, paths.parseSpec(self.spec).path, JOB_TIMEOUT_MS) catch |err| {
            if (editorio.isTransportError(err)) return err;
            return;
        };
        self.runs = res.runs;
        self.repo = res.repo;
        self.tracked = res.tracked;
        self.initial = res.initial;
        self.ok = true;
    }
};

/// Recompute `tab`'s gutter marks against HEAD. No-op without a
/// version-controlled project, with `editor_git_gutter = false`, or
/// while a refresh is already in flight.
pub fn refreshGit(view: *EditorView, tab: *ETab) void {
    if (!view.git_gutter) return;
    if (tab.git_gen != 0) return;
    const spec = tab.spec orelse return;
    const proj = tab.project orelse return;
    if (!proj.isVcs()) return;
    const job = wa.create(GitJob) catch return;
    const spec_copy = wa.dupe(u8, spec) catch {
        wa.destroy(job);
        return;
    };
    view.next_job_gen += 1;
    tab.git_gen = view.next_job_gen;
    tab.git.refreshing = true;
    view.fence.ref();
    job.* = .{
        .fence = view.fence,
        .tab_id = tab.id,
        .gen = tab.git_gen,
        .spec = spec_copy,
    };
    const th = c.g_thread_new("sketerm-gitgutter", @ptrCast(&gitThread), @ptrCast(job));
    if (th == null) {
        tab.git_gen = 0;
        tab.git.refreshing = false;
        job.destroy();
        return;
    }
    c.g_thread_unref(th);
}

fn gitThread(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const job = cast.userData(GitJob, data);
    editorio.withFs(paths.parseSpec(job.spec).host, job, GitJob.run) catch {};
    _ = c.g_idle_add(@ptrCast(&gitIdle), @ptrCast(job));
    return null;
}

fn gitIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(GitJob, user);
    defer job.destroy();
    const view = job.fence.viewIfAlive() orelse return 0;
    const tab = view.findTabById(job.tab_id) orelse return 0;
    if (tab.git_gen != job.gen) return 0;
    tab.git_gen = 0;
    tab.git.refreshing = false;
    if (!job.ok) return 0;

    // Outside a repository (or on a host without git) nothing is
    // KNOWN — an empty mark set would claim the file is clean.
    if (!job.repo) return 0;
    if (!job.tracked or job.initial) {
        // Nothing committed to compare against: every line is new.
        const marks = gitdiff.allAdded(view.allocator, &tab.doc) catch return 0;
        defer view.allocator.free(marks);
        tab.git.setFromLines(&tab.doc, marks) catch return 0;
    } else {
        const marks = gitdiff.linesFromRuns(view.allocator, job.runs) catch return 0;
        defer view.allocator.free(marks);
        tab.git.setFromLines(&tab.doc, marks) catch return 0;
    }
    view.queueRender();
    view.updateStatus();
    return 0;
}

/// Move the caret to the next / previous change hunk and reveal it.
/// Reports on the status line when there is nothing to jump to, so the
/// chord never looks broken.
pub fn stepHunk(view: *EditorView, forward: bool) void {
    const tab = view.activeTab() orelse return;
    if (tab.git.isEmpty()) {
        view.setStatusText(if (tab.git.known)
            "No changes against HEAD."
        else
            "No VCS information for this file.");
        return;
    }
    const at = tab.sels.primary().head;
    const target = tab.git.nextHunk(&tab.doc, at, forward) orelse return;
    const lc = tab.doc.rope.offsetToLineCol(target);
    view.gotoLineCol(tab, lc.line + 1, 1);
    var buf: [96:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Hunk {d} of {d}.", .{
        hunkIndexOf(tab, target) + 1,
        tab.git.hunkCount(&tab.doc),
    }) catch "Hunk.";
    view.setStatusText(msg.ptr);
}

fn hunkIndexOf(tab: *ETab, anchor: usize) usize {
    var n: usize = 0;
    var prev_line: ?usize = null;
    for (tab.git.list.items) |m| {
        const line = tab.doc.rope.offsetToLineCol(m.anchor).line;
        const starts = prev_line == null or line > prev_line.? + 1;
        if (starts) {
            if (m.anchor == anchor) return n;
            n += 1;
        }
        prev_line = line;
    }
    return 0;
}

// ======================================================================
// Project-wide search and replace
// ======================================================================

const SearchMode = enum { search, preview };

const SearchJob = struct {
    fence: *Fence,
    gen: u64,
    mode: SearchMode,
    host: []u8,
    root: []u8,
    root_spec: []u8,
    needle: []u8,
    replacement: []u8,
    opts: psearch.Options,
    max_files: u32,
    /// Built entirely on the worker and MOVED onto the view.
    results: *psearch.Results,
    err_buf: [96]u8 = undefined,
    err_len: usize = 0,

    fn setErr(self: *SearchJob, text: []const u8) void {
        self.err_len = @min(text.len, self.err_buf.len);
        @memcpy(self.err_buf[0..self.err_len], text[0..self.err_len]);
    }

    fn destroy(self: *SearchJob) void {
        wa.free(self.host);
        wa.free(self.root);
        wa.free(self.root_spec);
        wa.free(self.needle);
        wa.free(self.replacement);
        self.results.deinit();
        wa.destroy(self.results);
        self.fence.unref();
        wa.destroy(self);
    }
};

fn startSearchJob(view: *EditorView, mode: SearchMode) void {
    const tab = view.activeTab() orelse return;
    const proj = tab.project orelse {
        view.setStatusText("This file has no project (no VCS or build marker above it).");
        setSearchStatus(view, "No project: open a file inside a repository or a build root.");
        return;
    };
    const needle = entryText(view.search_entry);
    if (needle.len == 0) {
        setSearchStatus(view, "Type something to search for.");
        return;
    }
    const results = wa.create(psearch.Results) catch return;
    results.* = psearch.Results.init(wa);
    var spec_buf: [paths.SPEC_BUF_LEN]u8 = undefined;
    const root_spec = proj.rootSpec(&spec_buf);
    const opts = searchOptions(view);
    results.reset(root_spec, needle, opts) catch {
        results.deinit();
        wa.destroy(results);
        return;
    };
    const replacement = entryText(view.search_replace_entry);
    results.setReplacement(replacement) catch {};

    const job = wa.create(SearchJob) catch {
        results.deinit();
        wa.destroy(results);
        return;
    };
    view.search_gen += 1;
    view.fence.ref();
    job.* = .{
        .fence = view.fence,
        .gen = view.search_gen,
        .mode = mode,
        .host = wa.dupe(u8, proj.host) catch "",
        .root = wa.dupe(u8, proj.root) catch "",
        .root_spec = wa.dupe(u8, root_spec) catch "",
        .needle = wa.dupe(u8, needle) catch "",
        .replacement = wa.dupe(u8, replacement) catch "",
        .opts = opts,
        .max_files = view.search_max_files,
        .results = results,
    };
    view.replace_previewed = false;
    view.results.running = true;
    setSearchStatus(view, if (mode == .preview) "Previewing…" else "Searching…");
    const th = c.g_thread_new("sketerm-psearch", @ptrCast(&searchThread), @ptrCast(job));
    if (th == null) {
        view.results.running = false;
        job.destroy();
        return;
    }
    c.g_thread_unref(th);
}

fn searchThread(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const job = cast.userData(SearchJob, data);
    const host: ?[]const u8 = if (job.host.len == 0) null else job.host;
    editorio.withFs(host, job, searchOn) catch job.setErr("cannot reach the daemon");
    _ = c.g_idle_add(@ptrCast(&searchIdle), @ptrCast(job));
    return null;
}

/// The search body. Only a failure to START is returned (a stale pooled
/// connection shows there, before anything was collected), so a retry
/// never doubles a result set.
fn searchOn(job: *SearchJob, fs: *fsdrive.Fs) !void {
    const host: ?[]const u8 = if (job.host.len == 0) null else job.host;
    run: {
        // Candidate FILES from the daemon. The literal seed is what
        // grep can filter on; without one, every file under the root is
        // a candidate and the cap does the bounding.
        const seed = psearch.literalSeed(job.needle, job.opts);
        const djob = if (seed.len > 0)
            fs.startGrep(job.root, seed) catch |err| {
                if (editorio.isTransportError(err)) return err;
                job.setErr("could not start the search");
                break :run;
            }
        else
            fs.startFind(job.root, "*") catch |err| {
                if (editorio.isTransportError(err)) return err;
                job.setErr("could not start the search");
                break :run;
            };
        var end = fs.waitJobTerminal(djob, JOB_TIMEOUT_MS) catch {
            job.setErr("the search timed out");
            break :run;
        };
        const truncated = end.truncated;
        end.deinit();

        var candidates: std.ArrayList([]u8) = .empty;
        defer {
            for (candidates.items) |p| wa.free(p);
            candidates.deinit(wa);
        }
        while (fs.takeJobEvent()) |e0| {
            var e = e0;
            defer e.deinit();
            if (e.job != djob) continue;
            if (!std.mem.eql(u8, e.ev, "match")) continue;
            if (seed.len == 0 and !std.mem.eql(u8, e.kind, "file")) continue;
            if (candidates.items.len >= job.max_files) continue;
            var dup = false;
            for (candidates.items) |p| {
                if (std.mem.eql(u8, p, e.path)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            const copy = wa.dupe(u8, e.path) catch continue;
            candidates.append(wa, copy) catch {
                wa.free(copy);
                continue;
            };
        }
        job.results.truncated = truncated or candidates.items.len >= job.max_files;

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(wa);
        for (candidates.items) |path| {
            content.clearRetainingCapacity();
            var spec_buf: [paths.SPEC_BUF_LEN]u8 = undefined;
            const spec = paths.formatSpec(&spec_buf, host, path);
            const idx = job.results.addFile(spec) catch continue;
            editorio.readAllCapped(fs, path, &content, editorio.MAX_FILE_BYTES) catch {
                job.results.setNote(idx, "unreadable", .failed) catch {};
                continue;
            };
            _ = job.results.scanContent(idx, content.items) catch continue;
        }
    }
}

fn searchIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(SearchJob, user);
    const view_opt = job.fence.viewIfAlive();
    if (view_opt == null or view_opt.?.search_gen != job.gen) {
        job.destroy();
        return 0;
    }
    const view = view_opt.?;
    // Move the finished model onto the view; the job's own pointer is
    // reset so its destructor does not free what we just adopted.
    view.results.deinit();
    view.results = job.results.*;
    job.results.* = psearch.Results.init(wa);
    view.results.running = false;
    view.replace_previewed = job.mode == .preview;
    const err = job.err_buf[0..job.err_len];
    const had_err = job.err_len > 0;
    var err_copy: [96]u8 = undefined;
    @memcpy(err_copy[0..err.len], err);
    const err_len = err.len;
    job.destroy();

    rebuildResultRows(view);
    if (had_err) {
        var buf: [128:0]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s}", .{err_copy[0..err_len]}) catch "Search failed.";
        setSearchStatusZ(view, msg.ptr);
    } else updateSearchStatus(view);
    return 0;
}

// ---- the panel --------------------------------------------------------

pub fn buildPanel(view: *EditorView) void {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_visible(box, 0);
    c.gtk_widget_set_size_request(box, -1, 160);

    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_widget_add_css_class(row, "toolbar");
    const title = c.gtk_label_new("Project");
    c.gtk_widget_add_css_class(title, "dim-label");
    c.gtk_box_append(@ptrCast(row), title);

    const parts = findbar.build(row, .{
        .placeholder = "Find in project",
        .hexpand = true,
        .flat_toggles = false,
        .regex_tooltip = "Regular expression (same engine as the find bar)",
    }, .{
        .ctx = @ptrCast(view),
        .on_activate = @ptrCast(&onSearchActivate),
        .on_stop = @ptrCast(&onSearchStop),
        .on_toggle_changed = @ptrCast(&onOptionToggled),
    });
    view.search_entry = parts.entry;
    view.search_case = parts.case_btn;
    view.search_word = parts.word_btn;
    view.search_regex = parts.regex_btn;

    const go = c.gtk_button_new_with_label("Search");
    _ = c.g_signal_connect_data(go, "clicked", @ptrCast(&onSearchClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), go);
    _ = findbar.navButton(row, "window-close-symbolic", null, @ptrCast(&onSearchCloseClicked), @ptrCast(view));
    c.gtk_box_append(@ptrCast(box), row);

    const rrow = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    c.gtk_widget_add_css_class(rrow, "toolbar");
    const rentry = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(rentry), "Replace with — Enter previews, Ctrl+Enter applies");
    c.gtk_widget_set_hexpand(rentry, 1);
    _ = c.g_signal_connect_data(rentry, "activate", @ptrCast(&onPreviewActivate), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(rrow), rentry);
    view.search_replace_entry = rentry.?;
    const prev = c.gtk_button_new_with_label("Preview");
    c.gtk_widget_set_tooltip_text(prev, "List every file the replacement would change");
    _ = c.g_signal_connect_data(prev, "clicked", @ptrCast(&onPreviewClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(rrow), prev);
    view.search_preview_btn = prev.?;
    const apply = c.gtk_button_new_with_label("Apply");
    c.gtk_widget_set_tooltip_text(apply, "Replace in every listed file's buffer, opening it when needed; nothing is saved");
    c.gtk_widget_set_sensitive(apply, 0);
    _ = c.g_signal_connect_data(apply, "clicked", @ptrCast(&onApplyClicked), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(rrow), apply);
    view.search_apply_btn = apply.?;
    c.gtk_widget_set_visible(rrow, 0);
    c.gtk_box_append(@ptrCast(box), rrow);
    view.search_replace_row = rrow.?;

    const status = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(status), 0);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_widget_set_margin_start(status, 6);
    c.gtk_box_append(@ptrCast(box), status);
    view.search_status = @ptrCast(@alignCast(status));

    const scroll = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroll, 1);
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_SINGLE);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&onResultActivated), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), list);
    view.search_list = list.?;
    c.gtk_box_append(@ptrCast(box), scroll);

    // Escape anywhere in the panel closes it and returns focus to the
    // document — the find bar's contract, for the same reason.
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onPanelKey), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(box, @ptrCast(keys));

    view.search_panel = box.?;
}

fn searchOptions(view: *EditorView) psearch.Options {
    return .{
        .case_sensitive = c.gtk_toggle_button_get_active(@ptrCast(view.search_case)) != 0,
        .whole_word = c.gtk_toggle_button_get_active(@ptrCast(view.search_word)) != 0,
        .regex = c.gtk_toggle_button_get_active(@ptrCast(view.search_regex)) != 0,
    };
}

fn entryText(w: *c.GtkWidget) []const u8 {
    const buf = c.gtk_editable_get_text(@ptrCast(w)) orelse return "";
    return std.mem.span(buf);
}

/// Open the project panel; `replace` also reveals the replacement row.
/// Seeds the entry with the selection, like the find bar does.
pub fn openSearch(view: *EditorView, replace: bool) void {
    view.search_open = true;
    c.gtk_widget_set_visible(view.search_panel, 1);
    c.gtk_widget_set_visible(view.search_replace_row, if (replace) 1 else 0);
    if (view.activeTab()) |tab| {
        if (tab.project == null and tab.spec != null and tab.proj_gen == 0)
            resolveProject(view, tab);
    }
    updateSearchStatus(view);
    // Re-opening in replace mode with a needle already typed means
    // "now tell me what to replace it with".
    if (replace and entryText(view.search_entry).len > 0)
        _ = c.gtk_widget_grab_focus(view.search_replace_entry)
    else
        _ = c.gtk_widget_grab_focus(view.search_entry);
}

pub fn closeSearch(view: *EditorView) void {
    view.search_open = false;
    c.gtk_widget_set_visible(view.search_panel, 0);
    view.focusFace();
}

fn setSearchStatus(view: *EditorView, text: []const u8) void {
    var buf: [256:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return;
    setSearchStatusZ(view, z.ptr);
}

fn setSearchStatusZ(view: *EditorView, text: [*:0]const u8) void {
    c.gtk_label_set_text(view.search_status, text);
}

fn updateSearchStatus(view: *EditorView) void {
    const r = &view.results;
    var buf: [320:0]u8 = undefined;
    if (r.running) {
        setSearchStatus(view, "Searching…");
        return;
    }
    if (r.needle.len == 0) {
        const tab = view.activeTab();
        const proj = if (tab) |t| t.project else null;
        if (proj) |p| {
            const z = std.fmt.bufPrintZ(&buf, "Project: {s} ({s})", .{ p.label(), p.marker }) catch return;
            setSearchStatusZ(view, z.ptr);
        } else setSearchStatus(view, "No project for this file.");
        return;
    }
    const seed = psearch.literalSeed(r.needle, r.opts);
    const z = std.fmt.bufPrintZ(&buf, "{d} result(s) in {d} file(s) — {d} candidate(s) read{s}{s}{s}", .{
        r.hitCount(),
        r.matchedFiles(),
        r.scanned,
        if (r.truncated) ", truncated" else "",
        if (seed.len == 0 and r.opts.regex) ", no literal to pre-filter on" else "",
        if (view.replace_previewed) " — preview ready, press Apply" else "",
    }) catch return;
    setSearchStatusZ(view, z.ptr);
    c.gtk_widget_set_sensitive(view.search_apply_btn, if (view.replace_previewed) 1 else 0);
}

/// Rebuild the result rows. One row per FILE followed by one per hit;
/// hit rows carry their index as qdata so activation is a lookup, not a
/// scan.
fn rebuildResultRows(view: *EditorView) void {
    clearList(view.search_list);
    const r = &view.results;
    for (r.files.items, 0..) |f, fi| {
        if (f.hit_count == 0 and f.state != .failed) continue;
        var head: [512:0]u8 = undefined;
        const spec = r.fileSpec(@intCast(fi));
        const rel = relativeTo(r.root, spec);
        const head_z = if (f.state == .failed)
            std.fmt.bufPrintZ(&head, "{s} — {s}", .{ rel, r.note(@intCast(fi)) }) catch continue
        else if (view.replace_previewed)
            std.fmt.bufPrintZ(&head, "{s} ({d}) \u{2014} will be replaced in its buffer", .{ rel, f.hit_count }) catch continue
        else
            std.fmt.bufPrintZ(&head, "{s} ({d})", .{ rel, f.hit_count }) catch continue;
        appendRow(view, head_z.ptr, null, true);
        var h: u32 = 0;
        while (h < f.hit_count) : (h += 1) {
            const hi = f.first_hit + h;
            if (hi >= r.hits.items.len) break;
            const hit = r.hits.items[hi];
            var line_buf: [512:0]u8 = undefined;
            const text = std.fmt.bufPrintZ(&line_buf, "{d}: {s}", .{ hit.line + 1, r.preview(hit) }) catch continue;
            appendRow(view, text.ptr, hi, false);
        }
    }
}

fn relativeTo(root_spec: []const u8, spec: []const u8) []const u8 {
    const root = paths.parseSpec(root_spec).path;
    const path = paths.parseSpec(spec).path;
    if (std.mem.startsWith(u8, path, root) and path.len > root.len) {
        const skip: usize = if (root.len <= 1) 1 else root.len + 1;
        return path[@min(skip, path.len)..];
    }
    return path;
}

fn clearList(list: *c.GtkWidget) void {
    while (c.gtk_widget_get_first_child(list)) |child| {
        c.gtk_list_box_remove(@ptrCast(list), child);
    }
}

fn appendRow(view: *EditorView, text: [*:0]const u8, hit: ?u32, header: bool) void {
    const label = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_margin_start(label, if (header) 4 else 22);
    if (header) c.gtk_widget_add_css_class(label, "heading");
    const row = c.gtk_list_box_row_new();
    c.gtk_list_box_row_set_child(@ptrCast(row), label);
    c.gtk_list_box_row_set_activatable(@ptrCast(row), if (hit == null) 0 else 1);
    if (hit) |h| c.g_object_set_data(@ptrCast(@alignCast(row)), "psearch-hit", @ptrFromInt(@as(usize, h) + 1));
    c.gtk_list_box_append(@ptrCast(view.search_list), row);
}

fn onResultActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    const raw = c.g_object_get_data(@ptrCast(@alignCast(row)), "psearch-hit") orelse return;
    const idx: usize = @intFromPtr(raw) - 1;
    if (idx >= view.results.hits.items.len) return;
    const hit = view.results.hits.items[idx];
    const spec = view.results.fileSpec(hit.file);
    // Column is a BYTE column from the editor's own engine, so it lands
    // exactly on the match rather than on a re-guessed offset.
    view.openSpecAtLineCol(spec, hit.line + 1, hit.col + 1);
}

fn onSearchActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    startSearchJob(cast.userData(EditorView, user), .search);
}

fn onSearchClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    startSearchJob(cast.userData(EditorView, user), .search);
}

fn onPreviewClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    startSearchJob(cast.userData(EditorView, user), .preview);
}

fn onOptionToggled(_: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    view.replace_previewed = false;
    updateSearchStatus(view);
}

fn onSearchCloseClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    closeSearch(cast.userData(EditorView, user));
}

/// GtkSearchEntry "stop-search" (Esc in the entry). The panel's own
/// capture-phase Esc handler normally wins; this is the backstop.
fn onSearchStop(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
    closeSearch(cast.userData(EditorView, user));
}

/// Escape closes the panel; Ctrl+Enter applies a previewed replace
/// (the destructive half needs a modifier, and it is the one action
/// with no keyboard route through the entries).
fn onPanelKey(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const view = cast.userData(EditorView, user);
    const ctrl = (state & c.GDK_CONTROL_MASK) != 0;
    if (keyval == c.GDK_KEY_Escape) {
        closeSearch(view);
        return 1;
    }
    if (ctrl and (keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter)) {
        applyReplace(view);
        return 1;
    }
    return 0;
}

fn onPreviewActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    startSearchJob(cast.userData(EditorView, user), .preview);
}

// ---- applying a previewed replace -------------------------------------
//
// One policy with a language-server rename (docs/lsp.md): the change
// lands in BUFFERS, as one undoable transaction per file, and nothing is
// written to disk behind the user's back. A file with no tab is opened
// as one and gets its replacement when its load lands (the view's
// deferred-edit queue), re-planned against the text that actually
// arrived, so a file that changed since the preview is replaced as it
// is now rather than overwritten with a stale plan.

/// What a deferred project replace carries through the queue.
const ReplaceSpec = struct {
    needle: []const u8,
    template: []const u8,
    opts: psearch.Options,
};

/// Apply the previewed replace to every file that had hits.
fn applyReplace(view: *EditorView) void {
    if (!view.replace_previewed) {
        setSearchStatus(view, "Press Preview first.");
        return;
    }
    const r = &view.results;
    var payload: std.Io.Writer.Allocating = .init(view.allocator);
    defer payload.deinit();
    std.json.Stringify.value(ReplaceSpec{
        .needle = r.needle,
        .template = r.replacement,
        .opts = r.opts,
    }, .{}, &payload.writer) catch return;

    var now: usize = 0;
    var opening: usize = 0;
    var failed: usize = 0;
    for (r.files.items, 0..) |f, fi| {
        if (f.hit_count == 0) continue;
        const spec = r.fileSpec(@intCast(fi));
        const tab = view.tabForSpec(spec) orelse blk: {
            view.openSpec(spec, null);
            break :blk view.tabForSpec(spec) orelse {
                failed += 1;
                continue;
            };
        };
        if (tab.loading) {
            view.deferEdit(tab, .project_replace, payload.written()) catch {
                failed += 1;
                continue;
            };
            opening += 1;
            continue;
        }
        const n = replaceInDoc(view, tab, r.needle, r.replacement, r.opts) orelse {
            failed += 1;
            continue;
        };
        if (n > 0) now += 1;
    }

    view.replace_previewed = false;
    c.gtk_widget_set_sensitive(view.search_apply_btn, 0);
    var buf: [320:0]u8 = undefined;
    const msg = applyOutcome(&buf, now, opening, failed);
    setSearchStatusZ(view, msg.ptr);
    view.setStatusText(msg.ptr);
}

/// The outcome sentence, undo shape included (one undo step per file),
/// in the words a rename's outcome uses.
fn applyOutcome(buf: *[320:0]u8, now: usize, opening: usize, failed: usize) [:0]const u8 {
    const total = now + opening;
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print("Replaced in {d} file(s)", .{total}) catch {};
    if (total > 1) w.print(" \u{2014} {d} separate undo steps, one per file", .{total}) catch {};
    if (opening > 0) w.print("; {d} opened for it", .{opening}) catch {};
    if (failed > 0) w.print("; {d} could not be changed", .{failed}) catch {};
    if (total > 0) w.writeAll("; review and save (Save All)") catch {};
    w.writeAll(".") catch {};
    const n = w.end;
    buf[n] = 0;
    return buf[0..n :0];
}

/// A deferred replace for a file that just loaded: re-planned against
/// the text that arrived. @return whether anything changed.
pub fn applyDeferredReplace(view: *EditorView, tab: *ETab, payload: []const u8) bool {
    var parsed = std.json.parseFromSlice(ReplaceSpec, view.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    const spec = parsed.value;
    const n = replaceInDoc(view, tab, spec.needle, spec.template, spec.opts) orelse return false;
    return n > 0;
}

/// The files that had to be opened first got their replacement.
pub fn reportDeferredReplace(view: *EditorView, files: usize) void {
    var buf: [160:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Replaced in {d} more file(s) as they loaded; review and save.", .{files}) catch "Replaced.";
    view.setStatusText(msg.ptr);
}

fn onApplyClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    applyReplace(cast.userData(EditorView, user));
}

/// Replace every match in an OPEN document as one undoable transaction.
/// Returns the number of replacements, or null when the pattern does
/// not compile.
fn replaceInDoc(
    view: *EditorView,
    tab: *ETab,
    needle: []const u8,
    template: []const u8,
    opts: psearch.Options,
) ?usize {
    const applied = search.replaceAllIn(view.allocator, &tab.doc, &tab.sels, needle, template, opts) catch return null;
    if (applied > 0) view.afterExternalEdit(tab);
    return applied;
}

// ======================================================================
// Hooks the view calls
// ======================================================================

/// The active tab changed (or its content was replaced): refresh
/// everything project-scoped for it.
pub fn onTabActivated(view: *EditorView, tab: *ETab) void {
    if (tab.project == null and tab.spec != null and tab.proj_gen == 0) resolveProject(view, tab);
    if (view.git_gutter and tab.project != null) refreshGit(view, tab);
    if (view.search_open) updateSearchStatus(view);
}

/// Status-line fragment: the project label plus the gutter's hunk
/// count. Empty for a document with no project, so the status line of a
/// loose file is exactly what it always was.
pub fn statusFragment(view: *EditorView, tab: *ETab, buf: []u8) []const u8 {
    const proj = tab.project orelse {
        // Restored from the layout and not re-derived yet.
        const rp = tab.restored_project orelse return "";
        return std.fmt.bufPrint(buf, "  {s}", .{project_mod.labelOf(rp)}) catch "";
    };
    if (!view.git_gutter or tab.git.isEmpty()) {
        return std.fmt.bufPrint(buf, "  {s}", .{proj.label()}) catch "";
    }
    return std.fmt.bufPrint(buf, "  {s}  {d} hunk(s)", .{
        proj.label(),
        tab.git.hunkCount(&tab.doc),
    }) catch "";
}

// ======================================================================
// Tests
// ======================================================================

test "editorproj: the apply outcome states the undo shape" {
    const t = std.testing;
    var buf: [320:0]u8 = undefined;
    try t.expectEqualStrings(
        "Replaced in 3 file(s) \u{2014} 3 separate undo steps, one per file; 2 opened for it; review and save (Save All).",
        applyOutcome(&buf, 1, 2, 0),
    );
    try t.expectEqualStrings("Replaced in 1 file(s); review and save (Save All).", applyOutcome(&buf, 1, 0, 0));
    try t.expectEqualStrings("Replaced in 0 file(s); 1 could not be changed.", applyOutcome(&buf, 0, 0, 1));
}

test "editorproj: paths are shown relative to the project root" {
    const t = std.testing;
    try t.expectEqualStrings("src/a.zig", relativeTo("box:/proj", "box:/proj/src/a.zig"));
    try t.expectEqualStrings("a.zig", relativeTo("/", "/a.zig"));
    // Outside the root: the whole path, never a truncated one.
    try t.expectEqualStrings("/elsewhere/b.zig", relativeTo("/proj", "/elsewhere/b.zig"));
}
