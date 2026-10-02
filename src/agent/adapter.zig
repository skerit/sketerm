//! Agent adapters: the typed JSON schema an app's adapter file follows,
//! its validation, and loading of the shipped adapters (`data/agents/*.json`,
//! embedded through the build's generated `agent_adapters` module) plus
//! user overrides from `$XDG_CONFIG_HOME/sketerm/agents/*.json`.
//!
//! Adapters are data only. Unknown keys, unknown enum members and unknown
//! `{placeholders}` are errors with a file:line:column, never ignored, so a
//! typo cannot silently turn a rule off. Line rules are a `prefix` (the
//! common case) or a `pattern` in the `util/pattern.zig` regex subset.
//!
//! A module that calls `Set.loadShipped` must get the `agent_adapters`
//! import from build.zig's `addAgentAdapters`.

const std = @import("std");
const vocab = @import("vocab.zig");
const pattern = @import("../util/pattern.zig");
const readfile = @import("../util/readfile.zig");
const xdg = @import("../util/xdg.zig");
const c = @import("../c.zig").c;

// ── schema ───────────────────────────────────────────────────────

/// A single-line test: exactly one of `prefix` or `pattern`.
pub const LineRule = struct {
    prefix: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
};

pub const RecordRule = struct {
    kind: vocab.RecordKind,
    prefix: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    /// The record is its first line only; the lines after it start a
    /// record of this kind (a slash command's output after `you: /model`).
    then: ?vocab.RecordKind = null,
    /// `then` applies only when the record's text starts with this.
    then_when: ?[]const u8 = null,
};

pub const ErrorRule = struct {
    class: vocab.ErrorClass,
    prefix: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    /// The text after this marker on the matching line is the event's detail
    /// (a limit's reset time).
    reset_marker: ?[]const u8 = null,
};

pub const Launch = struct {
    /// The app's executable name.
    binary: []const u8,
    /// Ordered lookup on the host that runs the app: `$PATH` is a PATH search
    /// for `binary`, anything else a path (`~/` is that host's home). An SSH
    /// login shell does not add `~/.local/bin`, hence the explicit entries.
    candidates: []const []const u8,
    args: []const []const u8 = &.{},
    /// Appended when the caller names a model / an effort level.
    model_args: []const []const u8 = &.{},
    effort_args: []const []const u8 = &.{},
    /// The effort levels `effort_args` accepts; empty = any. A level
    /// outside it is refused before anything is started or stopped.
    effort_values: []const []const u8 = &.{},
    /// Appended on a fresh start: `{session}` is a conversation id (a UUID)
    /// the MCP layer mints, so a `relaunch` can resume exactly that one.
    session_args: []const []const u8 = &.{},
    /// Appended instead of `session_args` when a `relaunch` restarts an
    /// app whose conversation already has a turn.
    resume_args: []const []const u8 = &.{},
    /// How to end the app gracefully before a `relaunch` (a recipe; the
    /// app is killed when it has not exited shortly after).
    exit: []const Step = &.{},
    /// Removed from the app's environment; a trailing `*` removes every
    /// variable with that prefix.
    unset_env: []const []const u8 = &.{},
    /// API sources: the environment variable that hands the server its
    /// password (required for them; a password never goes on argv). The
    /// attached client reads the same variable.
    password_env: ?[]const u8 = null,
    /// API sources: arguments of a second, visible process the human
    /// watches (opencode's TUI attached to the server); empty for none.
    attach_args: []const []const u8 = &.{},
    /// Arguments that make the binary print its version, whose first line
    /// is reported with the resolved path; empty = not asked.
    version_args: []const []const u8 = &.{},
};

pub const TurnEnd = enum {
    /// OSC 133 D (`Screen.cmd_completion_seq`).
    osc133,
};

/// Rules for a `screen` source.
pub const ScreenSpec = struct {
    /// Line prefix of the app's input box: the live region's anchor, and
    /// readiness (typing before it shows is lost).
    input_prefix: []const u8,
    /// Readiness also needs the screen quiet this long.
    ready_settle_ms: u32 = 800,
    /// Title prefixes meaning busy (working or waiting on a subagent).
    busy_title: []const []const u8,
    turn_end: TurnEnd = .osc133,
    /// A line proving the turn's text is fully drawn; the turn is captured
    /// as soon as it shows below the turn's last record.
    footer: ?LineRule = null,
    /// Guard for a turn end without a footer: capture this long after it.
    settle_ms: u32 = 1500,
    records: []const RecordRule,
    /// Lines that end the current record; text after them is dropped until
    /// the next record starts.
    chrome: []const LineRule = &.{},
    /// "Waiting for N background agents" style line: busy is a subagent wait.
    subagent: ?LineRule = null,
    /// A line saying background tasks the app started still run (its
    /// numbers summed are their count, 1 when it has none): an idle app
    /// showing it is `waiting_background`, and its `done` waits for them.
    background: ?LineRule = null,
    /// A row the app draws for each background subagent still running:
    /// counted with `background`'s tasks.
    background_agent: ?LineRule = null,
    /// The line under a numbered option list (`N. label` rows) that makes
    /// it a pending interaction.
    choice_prompt: LineRule,
    selected_marker: []const u8 = "(selected)",
    /// A line above the options that makes the interaction a permission.
    permission: ?LineRule = null,
    /// A lone BEL (one not part of a turn end) means the app wants input.
    bell_needs_input: bool = false,
    /// The line the app draws under prompts it queued (typed while it
    /// works) until it takes them: the user records directly above it are
    /// previews, never transcript, and an idle app showing it is not done.
    queued: ?LineRule = null,
    /// Options a free-text answer goes through (`actions.answer_text`
    /// picks the first that matches, then types the text).
    text_options: []const TextOption = &.{},
    /// A line the app prints when `launch.resume_args` named a conversation
    /// it does not have: `agent_open resume` then fails naming the id, and
    /// no new conversation is left running in its name.
    resume_refused: ?LineRule = null,
};

/// An interaction option that takes free text: its label matches exactly
/// one of `prefix`/`pattern`, in an interaction of `kind` (any when null).
pub const TextOption = struct {
    kind: ?vocab.InteractionKind = null,
    prefix: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
};

pub const WaitFor = enum {
    ready,
    choice,
    idle,
    /// The interaction showing when the recipe started is gone.
    answered,
};

/// One step of an action recipe, run by the MCP layer. `text`, `command`
/// and `pick` expand `{placeholders}`.
pub const Step = union(enum) {
    /// Typed as one write.
    text: []const u8,
    /// Typed like `text`, but it is the adapter's own command (`/model`):
    /// its turn never reaches the transcript or the events, and the
    /// interaction it opens is the recipe's to answer, not the assistant's.
    command: []const u8,
    /// A key name as the MCP `send_keys` tools spell it (`enter`, `escape`, `s`).
    key: []const u8,
    sleep_ms: u32,
    /// Keys that empty the input box, sent only when it is not empty.
    clear_input: []const []const u8,
    wait: WaitFor,
    /// Choose an option of the pending interaction by label or 1-based
    /// index (types its number).
    pick: []const u8,
    /// The action took effect: no interaction shows and a line matching
    /// this rule appeared below the recipe's `command`. A recipe never
    /// reports success before it.
    confirm: LineRule,
    /// End the app (`launch.exit`) and start it again in the same session
    /// with `launch.resume_args` and every launch value as set now (the
    /// effort an app only takes at launch). Last step of its recipe.
    relaunch: struct {},
};

pub const Actions = struct {
    submit: []const Step = &.{},
    /// Typing a prompt while the app works, for its native queue; empty when
    /// it has none (a busy agent then refuses prompts).
    queue: []const Step = &.{},
    answer: []const Step = &.{},
    /// A free-text answer: `{choice}` is the option `screen.text_options`
    /// matched, `{text}` the caller's text.
    answer_text: []const Step = &.{},
    interrupt: []const Step = &.{},
    set_model: []const Step = &.{},
    set_effort: []const Step = &.{},
};

pub const Spec = struct {
    id: []const u8,
    name: []const u8,
    source: vocab.SourceKind,
    launch: Launch,
    screen: ?ScreenSpec = null,
    actions: Actions = .{},
    errors: []const ErrorRule = &.{},
};

/// The `{name}`s a recipe or launch argument may use. `port` and `cwd` are
/// an API source's server port and working directory; `session` is the
/// app's conversation: an API source's session id, or the id minted for
/// `session_args` / `resume_args`.
pub const Placeholder = enum { text, choice, model, effort, port, cwd, session };

// ── compiled form ────────────────────────────────────────────────

pub const Matcher = union(enum) {
    prefix: []const u8,
    pattern: pattern.Matcher,

    pub fn matches(self: Matcher, line: []const u8) bool {
        return switch (self) {
            .prefix => |p| std.mem.startsWith(u8, line, p),
            .pattern => |m| m.matches(line),
        };
    }
};

/// Compile one line rule (the validator has checked every rule a loaded
/// adapter holds, so on those only OutOfMemory can happen).
pub fn compileLine(arena: std.mem.Allocator, r: LineRule) error{ NotOneRule, EmptyPrefix, BadPattern, OutOfMemory }!Matcher {
    if ((r.prefix == null) == (r.pattern == null)) return error.NotOneRule;
    if (r.prefix) |p| {
        if (p.len == 0) return error.EmptyPrefix;
        return .{ .prefix = p };
    }
    return .{ .pattern = try pattern.compile(arena, r.pattern.?, false) };
}

pub const RecordMatcher = struct {
    kind: vocab.RecordKind,
    matcher: Matcher,
    /// Bytes stripped from the first line (the prefix; 0 for a pattern).
    strip: usize,
    then: ?vocab.RecordKind,
    then_when: ?[]const u8,
};

pub const ErrorMatcher = struct {
    class: vocab.ErrorClass,
    matcher: Matcher,
    reset_marker: ?[]const u8,
};

pub const Screen = struct {
    spec: *const ScreenSpec,
    footer: ?Matcher,
    records: []const RecordMatcher,
    chrome: []const Matcher,
    subagent: ?Matcher,
    background: ?Matcher,
    background_agent: ?Matcher,
    choice_prompt: Matcher,
    permission: ?Matcher,
    queued: ?Matcher,
    text_options: []const TextOptionMatcher,
    resume_refused: ?Matcher,
};

pub const TextOptionMatcher = struct {
    kind: ?vocab.InteractionKind,
    matcher: Matcher,
};

pub const Origin = enum { shipped, user };

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    spec: Spec,
    /// Present exactly when `spec.source == .screen`.
    screen: ?Screen,
    errors: []const ErrorMatcher,
    origin: Origin,
    /// `shipped:<file>` or the user file's path.
    source: []const u8,

    pub fn destroy(self: *Loaded, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

// ── parsing and validation ───────────────────────────────────────

/// Parse and validate one adapter file.
/// @param problem receives a one-line reason (allocated from `allocator`) on error.InvalidAdapter.
pub fn load(allocator: std.mem.Allocator, source: []const u8, bytes: []const u8, origin: Origin, problem: *?[]u8) !*Loaded {
    const self = try allocator.create(Loaded);
    self.arena = std.heap.ArenaAllocator.init(allocator);
    errdefer self.destroy(allocator);
    const a = self.arena.allocator();
    self.origin = origin;
    self.source = try a.dupe(u8, source);

    var scanner = std.json.Scanner.initCompleteInput(a, bytes);
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    self.spec = std.json.parseFromTokenSourceLeaky(Spec, a, &scanner, .{ .allocate = .alloc_always }) catch |err| {
        problem.* = try jsonProblem(allocator, source, bytes, &diag, err);
        return error.InvalidAdapter;
    };
    var v: Validator = .{ .arena = a, .gpa = allocator, .source = source, .problem = problem };
    try v.check(self);
    return self;
}

fn jsonProblem(allocator: std.mem.Allocator, source: []const u8, bytes: []const u8, diag: *const std.json.Diagnostics, err: anyerror) ![]u8 {
    const off: usize = @intCast(@min(diag.getByteOffset(), bytes.len));
    if (err == error.UnknownField) {
        // The scanner stops right after the offending key's closing quote.
        const close = std.mem.lastIndexOfScalar(u8, bytes[0..off], '"');
        const open = if (close) |cq| std.mem.lastIndexOfScalar(u8, bytes[0..cq], '"') else null;
        if (open != null and close != null) {
            return std.fmt.allocPrint(allocator, "{s}:{d}:{d}: unknown key \"{s}\"", .{
                source, diag.getLine(), diag.getColumn(), bytes[open.? + 1 .. close.?],
            });
        }
    }
    return std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ source, diag.getLine(), diag.getColumn(), @errorName(err) });
}

const Validator = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    source: []const u8,
    problem: *?[]u8,

    fn fail(self: *Validator, comptime fmt: []const u8, args: anytype) error{ InvalidAdapter, OutOfMemory } {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.OutOfMemory;
        defer self.gpa.free(msg);
        self.problem.* = std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ self.source, msg }) catch return error.OutOfMemory;
        return error.InvalidAdapter;
    }

    fn check(self: *Validator, l: *Loaded) !void {
        const s = &l.spec;
        if (!validId(s.id)) return self.fail("id \"{s}\" must be 1-32 chars of [a-z0-9_-]", .{s.id});
        if (s.launch.candidates.len == 0) return self.fail("launch.candidates is empty", .{});
        for (s.launch.args) |x| try self.placeholders(x, "launch.args");
        for (s.launch.model_args) |x| try self.placeholders(x, "launch.model_args");
        for (s.launch.effort_args) |x| try self.placeholders(x, "launch.effort_args");
        for (s.launch.attach_args) |x| try self.placeholders(x, "launch.attach_args");
        for (s.launch.session_args) |x| try self.placeholders(x, "launch.session_args");
        for (s.launch.resume_args) |x| try self.placeholders(x, "launch.resume_args");
        if ((s.launch.session_args.len == 0) != (s.launch.resume_args.len == 0))
            return self.fail("launch.session_args and launch.resume_args go together (a relaunch resumes the conversation the start named)", .{});
        if (s.launch.effort_values.len > 0 and s.launch.effort_args.len == 0)
            return self.fail("launch.effort_values without launch.effort_args", .{});
        if (s.launch.password_env) |name| {
            if (!validEnvName(name)) return self.fail("launch.password_env \"{s}\" is not an environment variable name", .{name});
        }
        for (s.launch.unset_env) |name| {
            const base = if (std.mem.endsWith(u8, name, "*")) name[0 .. name.len - 1] else name;
            if (!validEnvName(base)) return self.fail("launch.unset_env \"{s}\" is not a variable name (a trailing * matches a prefix)", .{name});
        }
        try self.recipe(s, s.launch.exit, "launch.exit");
        inline for (@typeInfo(Actions).@"struct".fields) |f| try self.recipe(s, @field(s.actions, f.name), "actions." ++ f.name);
        const errs = try self.arena.alloc(ErrorMatcher, s.errors.len);
        for (s.errors, errs, 0..) |r, *out, i| {
            out.* = .{
                .class = r.class,
                .matcher = try self.rule(.{ .prefix = r.prefix, .pattern = r.pattern }, "errors", i),
                .reset_marker = r.reset_marker,
            };
        }
        l.errors = errs;
        l.screen = null;
        switch (s.source) {
            .screen => {
                const sc = if (s.screen) |*x| x else return self.fail("source \"screen\" needs a \"screen\" section", .{});
                l.screen = try self.screen(sc);
                if ((sc.text_options.len == 0) != (s.actions.answer_text.len == 0))
                    return self.fail("screen.text_options and actions.answer_text go together (the recipe answers through the option the rules match)", .{});
            },
            .opencode_api => {
                if (s.screen != null) return self.fail("source \"opencode_api\" takes no \"screen\" section", .{});
                if (s.launch.password_env == null) return self.fail("source \"opencode_api\" needs launch.password_env", .{});
            },
        }
    }

    fn recipe(self: *Validator, s: *const Spec, steps: []const Step, where: []const u8) !void {
        var commanded = false;
        for (steps, 0..) |step, i| switch (step) {
            .text, .pick => |x| try self.placeholders(x, where),
            .command => |x| {
                if (x.len == 0) return self.fail("{s}: empty command", .{where});
                try self.placeholders(x, where);
                commanded = true;
            },
            .key => |x| if (x.len == 0) return self.fail("{s}: empty key", .{where}),
            .clear_input => |keys| {
                if (keys.len == 0) return self.fail("{s}: clear_input names no key", .{where});
                for (keys) |k| if (k.len == 0) return self.fail("{s}: empty key", .{where});
            },
            .sleep_ms, .wait => {},
            .confirm => |r| {
                if (!commanded) return self.fail("{s}: confirm needs a command step before it (it looks below that command)", .{where});
                _ = try self.rule(r, where, i);
            },
            .relaunch => {
                if (s.source != .screen) return self.fail("{s}: relaunch is for screen sources (an API source takes settings per request)", .{where});
                if (s.launch.resume_args.len == 0) return self.fail("{s}: relaunch needs launch.session_args and launch.resume_args", .{where});
                if (s.launch.exit.len == 0) return self.fail("{s}: relaunch needs launch.exit", .{where});
                if (steps.ptr == s.launch.exit.ptr) return self.fail("{s}: an exit recipe cannot relaunch", .{where});
                if (i + 1 != steps.len) return self.fail("{s}: relaunch must be the last step", .{where});
            },
        };
    }

    fn screen(self: *Validator, sc: *const ScreenSpec) !Screen {
        if (sc.input_prefix.len == 0) return self.fail("screen.input_prefix is empty", .{});
        if (sc.busy_title.len == 0) return self.fail("screen.busy_title is empty", .{});
        if (sc.records.len == 0) return self.fail("screen.records is empty", .{});
        const recs = try self.arena.alloc(RecordMatcher, sc.records.len);
        for (sc.records, recs, 0..) |r, *out, i| {
            const m = try self.rule(.{ .prefix = r.prefix, .pattern = r.pattern }, "screen.records", i);
            if (r.then_when != null and r.then == null)
                return self.fail("screen.records[{d}]: then_when without then", .{i});
            out.* = .{ .kind = r.kind, .matcher = m, .strip = if (r.prefix) |p| p.len else 0, .then = r.then, .then_when = r.then_when };
        }
        const chrome = try self.arena.alloc(Matcher, sc.chrome.len);
        for (sc.chrome, chrome, 0..) |r, *out, i| out.* = try self.rule(r, "screen.chrome", i);
        const texts = try self.arena.alloc(TextOptionMatcher, sc.text_options.len);
        for (sc.text_options, texts, 0..) |r, *out, i| out.* = .{ .kind = r.kind, .matcher = try self.rule(.{ .prefix = r.prefix, .pattern = r.pattern }, "screen.text_options", i) };
        return .{
            .spec = sc,
            .footer = if (sc.footer) |r| try self.rule(r, "screen.footer", null) else null,
            .records = recs,
            .chrome = chrome,
            .subagent = if (sc.subagent) |r| try self.rule(r, "screen.subagent", null) else null,
            .background = if (sc.background) |r| try self.rule(r, "screen.background", null) else null,
            .background_agent = if (sc.background_agent) |r| try self.rule(r, "screen.background_agent", null) else null,
            .choice_prompt = try self.rule(sc.choice_prompt, "screen.choice_prompt", null),
            .permission = if (sc.permission) |r| try self.rule(r, "screen.permission", null) else null,
            .queued = if (sc.queued) |r| try self.rule(r, "screen.queued", null) else null,
            .text_options = texts,
            .resume_refused = if (sc.resume_refused) |r| try self.rule(r, "screen.resume_refused", null) else null,
        };
    }

    fn rule(self: *Validator, r: LineRule, where: []const u8, index: ?usize) !Matcher {
        var ibuf: [24]u8 = undefined;
        const idx: []const u8 = if (index) |i| std.fmt.bufPrint(&ibuf, "[{d}]", .{i}) catch "" else "";
        return compileLine(self.arena, r) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotOneRule => return self.fail("{s}{s}: needs exactly one of \"prefix\" or \"pattern\"", .{ where, idx }),
            error.EmptyPrefix => return self.fail("{s}{s}: empty prefix", .{ where, idx }),
            error.BadPattern => return self.fail("{s}{s}: bad pattern \"{s}\"", .{ where, idx, r.pattern.? }),
        };
    }

    fn placeholders(self: *Validator, s: []const u8, where: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, s, i, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, s, open, '}') orelse
                return self.fail("{s}: unclosed \"{{\" in \"{s}\"", .{ where, s });
            const name = s[open + 1 .. close];
            if (std.meta.stringToEnum(Placeholder, name) == null)
                return self.fail("{s}: unknown placeholder {{{s}}} in \"{s}\"", .{ where, name, s });
            i = close + 1;
        }
    }
};

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |ch| {
        if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-')) return false;
    }
    return true;
}

/// Expand `{placeholder}`s in `s`; a placeholder without a value expands to "".
pub fn expand(allocator: std.mem.Allocator, s: []const u8, values: std.enums.EnumFieldStruct(Placeholder, ?[]const u8, @as(?[]const u8, null))) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, s, i, '}')) |close| {
                if (std.meta.stringToEnum(Placeholder, s[i + 1 .. close])) |ph| {
                    const v: ?[]const u8 = switch (ph) {
                        inline else => |tag| @field(values, @tagName(tag)),
                    };
                    try out.appendSlice(allocator, v orelse "");
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// ── the adapter set ──────────────────────────────────────────────

/// Largest adapter file read from the user's config.
pub const MAX_FILE_BYTES: usize = 256 * 1024;

pub const Set = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*Loaded) = .empty,
    /// One line per file that failed to load; a failed user override leaves
    /// the shipped adapter of that id in place.
    problems: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Set) void {
        for (self.items.items) |l| l.destroy(self.allocator);
        self.items.deinit(self.allocator);
        for (self.problems.items) |p| self.allocator.free(p);
        self.problems.deinit(self.allocator);
    }

    /// Shipped adapters plus the user's overrides.
    pub fn loadDefault(allocator: std.mem.Allocator) !Set {
        var set = Set.init(allocator);
        errdefer set.deinit();
        try set.loadShipped();
        var buf: [4096]u8 = undefined;
        if (xdg.configDir(&buf)) |cfg| {
            var dbuf: [4200]u8 = undefined;
            const dir = std.fmt.bufPrint(&dbuf, "{s}/agents", .{cfg}) catch return set;
            try set.loadDir(dir);
        }
        return set;
    }

    pub fn loadShipped(self: *Set) !void {
        for (@import("agent_adapters").shipped) |f| {
            var name_buf: [128]u8 = undefined;
            const src = std.fmt.bufPrint(&name_buf, "shipped:{s}", .{f.file}) catch f.file;
            try self.addSource(src, f.json, .shipped);
        }
    }

    /// Every `*.json` in `dir`, in name order; a missing directory is no error.
    pub fn loadDir(self: *Set, dir: []const u8) !void {
        var zbuf: [4096]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&zbuf, "{s}", .{dir}) catch return;
        const d = c.opendir(dz.ptr) orelse return;
        defer _ = c.closedir(d);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        while (c.readdir(d)) |de| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&de.*.d_name)), 0);
            if (name.len == 0 or name[0] == '.' or !std.mem.endsWith(u8, name, ".json")) continue;
            try names.append(self.allocator, try self.allocator.dupe(u8, name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |n| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, n });
            defer self.allocator.free(path);
            const bytes = readfile.cappedAlloc(self.allocator, path, MAX_FILE_BYTES) catch |err| {
                try self.problems.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ path, @errorName(err) }));
                continue;
            };
            defer self.allocator.free(bytes);
            try self.addSource(path, bytes, .user);
        }
    }

    /// Parse one file into the set; a later adapter with the same id replaces
    /// the earlier one.
    pub fn addSource(self: *Set, source: []const u8, bytes: []const u8, origin: Origin) !void {
        var problem: ?[]u8 = null;
        const l = load(self.allocator, source, bytes, origin, &problem) catch |err| switch (err) {
            error.InvalidAdapter => {
                try self.problems.append(self.allocator, problem.?);
                return;
            },
            else => return err,
        };
        for (self.items.items) |*slot| {
            if (std.mem.eql(u8, slot.*.spec.id, l.spec.id)) {
                slot.*.destroy(self.allocator);
                slot.* = l;
                return;
            }
        }
        self.items.append(self.allocator, l) catch |err| {
            l.destroy(self.allocator);
            return err;
        };
    }

    pub fn get(self: *const Set, id: []const u8) ?*const Loaded {
        for (self.items.items) |l| {
            if (std.mem.eql(u8, l.spec.id, id)) return l;
        }
        return null;
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

const minimal =
    \\{
    \\  "id": "demo",
    \\  "name": "Demo",
    \\  "source": "screen",
    \\  "launch": { "binary": "demo", "candidates": ["$PATH"], "model_args": ["--model", "{model}"] },
    \\  "screen": {
    \\    "input_prefix": "> ",
    \\    "busy_title": ["*"],
    \\    "records": [ { "kind": "user", "prefix": "you: " }, { "kind": "notice", "pattern": "^Done [0-9]+" } ],
    \\    "choice_prompt": { "prefix": "Select with numbers" }
    \\  },
    \\  "actions": { "submit": [ { "text": "{text}" }, { "sleep_ms": 800 }, { "key": "enter" } ] },
    \\  "errors": [ { "class": "limit", "prefix": "Usage limit reached", "reset_marker": "resets " } ]
    \\}
;

fn expectProblem(json: []const u8, needle: []const u8) !void {
    var problem: ?[]u8 = null;
    try t.expectError(error.InvalidAdapter, load(t.allocator, "x.json", json, .user, &problem));
    defer t.allocator.free(problem.?);
    if (std.mem.indexOf(u8, problem.?, needle) == null) {
        std.debug.print("problem: {s}\n", .{problem.?});
        return error.TestUnexpectedProblem;
    }
}

test "a minimal adapter parses and compiles its rules" {
    var problem: ?[]u8 = null;
    const l = try load(t.allocator, "demo.json", minimal, .user, &problem);
    defer l.destroy(t.allocator);
    const sc = l.screen.?;
    try t.expectEqual(@as(usize, 5), sc.records[0].strip);
    try t.expect(sc.records[1].matcher.matches("Done 3 things"));
    try t.expect(!sc.records[1].matcher.matches("Not Done 3"));
    try t.expect(sc.choice_prompt.matches("Select with numbers [1-3]."));
    try t.expectEqual(vocab.ErrorClass.limit, l.errors[0].class);
    try t.expectEqual(@as(u32, 800), l.spec.actions.submit[1].sleep_ms);
}

test "unknown keys are rejected with the key and its position" {
    const bad = std.mem.replaceOwned(u8, t.allocator, minimal, "\"busy_title\"", "\"busy_titel\"") catch unreachable;
    defer t.allocator.free(bad);
    try expectProblem(bad, "x.json:8:");
    try expectProblem(bad, "unknown key \"busy_titel\"");
}

test "semantic errors name the rule" {
    const both = std.mem.replaceOwned(u8, t.allocator, minimal, "\"prefix\": \"you: \"", "\"prefix\": \"you: \", \"pattern\": \"x\"") catch unreachable;
    defer t.allocator.free(both);
    try expectProblem(both, "screen.records[0]: needs exactly one of");

    const badpat = std.mem.replaceOwned(u8, t.allocator, minimal, "^Done [0-9]+", "[0-9") catch unreachable;
    defer t.allocator.free(badpat);
    try expectProblem(badpat, "screen.records[1]: bad pattern");

    const ph = std.mem.replaceOwned(u8, t.allocator, minimal, "{text}", "{txet}") catch unreachable;
    defer t.allocator.free(ph);
    try expectProblem(ph, "unknown placeholder {txet}");

    const kind = std.mem.replaceOwned(u8, t.allocator, minimal, "\"notice\"", "\"remark\"") catch unreachable;
    defer t.allocator.free(kind);
    try expectProblem(kind, "InvalidEnumTag");

    const noscreen = std.mem.replaceOwned(u8, t.allocator, minimal, "\"screen\": {", "\"screenx\": {") catch unreachable;
    defer t.allocator.free(noscreen);
    try expectProblem(noscreen, "unknown key \"screenx\"");
}

test "an API source needs a password variable and checks its attach arguments" {
    const api =
        \\{ "id": "api", "name": "API", "source": "opencode_api",
        \\  "launch": { "binary": "x", "candidates": ["$PATH"], "args": ["serve", "--port", "{port}"],
        \\              "password_env": "X_PASSWORD", "attach_args": ["attach", "{session}"] } }
    ;
    var problem: ?[]u8 = null;
    const l = try load(t.allocator, "api.json", api, .user, &problem);
    l.destroy(t.allocator);

    const no_pw = std.mem.replaceOwned(u8, t.allocator, api, "\"password_env\": \"X_PASSWORD\", ", "") catch unreachable;
    defer t.allocator.free(no_pw);
    try expectProblem(no_pw, "needs launch.password_env");
    const bad_env = std.mem.replaceOwned(u8, t.allocator, api, "X_PASSWORD", "X-PASSWORD") catch unreachable;
    defer t.allocator.free(bad_env);
    try expectProblem(bad_env, "is not an environment variable name");
    const bad_ph = std.mem.replaceOwned(u8, t.allocator, api, "{session}", "{sesion}") catch unreachable;
    defer t.allocator.free(bad_ph);
    try expectProblem(bad_ph, "launch.attach_args: unknown placeholder {sesion}");
    // unset_env entries are names with an optional trailing * (they end up
    // in a shell case pattern), never anything else.
    const unset_ok = std.mem.replaceOwned(u8, t.allocator, api, "\"password_env\"", "\"unset_env\": [\"CLAUDE*\", \"X_TOKEN\"], \"password_env\"") catch unreachable;
    defer t.allocator.free(unset_ok);
    const l2 = try load(t.allocator, "api.json", unset_ok, .user, &problem);
    l2.destroy(t.allocator);
    const unset_bad = std.mem.replaceOwned(u8, t.allocator, api, "\"password_env\"", "\"unset_env\": [\"A;B*\"], \"password_env\"") catch unreachable;
    defer t.allocator.free(unset_bad);
    try expectProblem(unset_bad, "launch.unset_env \"A;B*\" is not a variable name");
}

test "expand fills known placeholders and leaves other braces alone" {
    const s = try expand(t.allocator, "/model {model} {x}", .{ .model = "opus" });
    defer t.allocator.free(s);
    try t.expectEqualStrings("/model opus {x}", s);
}

test "every shipped adapter loads, and a user file overrides by id" {
    var set = Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    if (set.problems.items.len > 0) {
        for (set.problems.items) |p| std.debug.print("shipped adapter problem: {s}\n", .{p});
        return error.ShippedAdapterInvalid;
    }
    try t.expect(set.items.items.len >= 2);
    try t.expect(set.get("claude") != null);
    // What `claude --resume <unknown id>` prints before it exits 1 (measured, 2.1.287).
    try t.expect(set.get("claude").?.screen.?.resume_refused.?.matches("No conversation found with session ID: 00000000-0000-4000-8000-00000000beef"));
    const oc = set.get("opencode").?;
    try t.expectEqual(vocab.SourceKind.opencode_api, oc.spec.source);
    try t.expectEqualStrings("OPENCODE_SERVER_PASSWORD", oc.spec.launch.password_env.?);

    const user = std.mem.replaceOwned(u8, t.allocator, minimal, "\"demo\"", "\"claude\"") catch unreachable;
    defer t.allocator.free(user);
    try set.addSource("user.json", user, .user);
    try t.expectEqual(Origin.user, set.get("claude").?.origin);
    try set.addSource("broken.json", "{", .user);
    try t.expectEqual(@as(usize, 1), set.problems.items.len);
    try t.expectEqual(Origin.user, set.get("claude").?.origin);
}
