# MCP structured results — design (2026-08-21)

Status: BINDING for the structured-results migration. Waves 1-3 are
SHIPPED (2026-08-21): every tool speaks both lanes and declares an
`output_schema`. Read fully before touching `src/ipc/mcp*.zig` — this
is the contract a NEW tool has to meet, not a plan.

## Goal

Every tool result carries BOTH lanes, each doing the one job it is good at:

- `structuredContent` — the machine-readable facts. JSON object, facts only:
  no prose hints, no `note`/`hint`/`reading_hint` fields, no instructions
  about which tool to call next.
- `content` — exactly one text block of token-efficient HUMAN/model prose.
  NEVER JSON. Never empty (older MCP clients render only this lane).
  Compact `key: value` lines or short sentences; large payloads (screen
  text, article text, snapshots, file content) stay plain text here.

Images/media stay proper MCP image content blocks (after the text block),
with their metadata (width/height/tags) in `structuredContent`.

Errors are uniform:

```json
{"content":[{"type":"text","text":"no web view with id 4 (web_tabs lists them)"}],
 "structuredContent":{"error":{"code":"not_found","message":"no web view with id 4 (web_tabs lists them)","retryable":false}},
 "isError":true}
```

There is no `ok` field: `isError` already carries success/failure.
Results that are "soft failures" today with `isError:false` (app_actions
step failures, `commandCompletionResult` timeouts, `fsAwaitJob` timeout)
KEEP `isError:false` — their outcome is a fact in `structuredContent`
(e.g. `status`, `timed_out`), not a tool error. Do not change that
semantics during migration.

## The builder: `Res` (in `src/ipc/mcp.zig`, pub, used by all modules)

One builder producing both lanes in a single pass. Zig 0.16
(`std.Io.Writer.Allocating`, unmanaged containers), arena-allocated,
NDJSON-safe (the serialized result must contain no raw `\n`; newlines
inside JSON strings are escaped by the stringifier — fine).

```zig
pub const Res = struct {
    pub fn init(arena: std.mem.Allocator) Res;

    // Adds "name":<json> to structuredContent AND an auto "name: value"
    // line to the text lane. Value rendering in text: strings bare
    // (unquoted), bools true/false, numbers plain.
    pub fn field(self: *Res, name: []const u8, value: anytype) !void;

    // structuredContent only — for facts a human does not need
    // (revision counters, ids already shown, big arrays).
    pub fn fact(self: *Res, name: []const u8, value: anytype) !void;

    // Verbatim JSON into structuredContent only (pre-serialized payloads
    // such as snapshot trees). No text.
    pub fn raw(self: *Res, name: []const u8, json: []const u8) !void;

    // Free-form line(s) appended to the text lane only. Used for the
    // prose that used to live in note/hint JSON fields, and for large
    // plain payloads (screen text etc.). May contain newlines.
    pub fn text(self: *Res, line: []const u8) !void;
    pub fn textf(self: *Res, comptime fmt: []const u8, args: anytype) !void;

    // Serialize: {"content":[{"type":"text","text":...}],"structuredContent":{...}}
    // If the text lane is empty, emit "ok" (never an empty text block).
    pub fn finish(self: *Res) ![]const u8;

    // Optional image blocks: same as finish but content gains image
    // blocks after the text block (replaces imageResult*/imagesResult*
    // eventually; those helpers are rewritten on top of Res).
    pub fn finishWithImages(self: *Res, pngs: []const []const u8, tags: ?[]const []const u8) ![]const u8;
};
```

Text auto-lane detail: `field` writes `name: value\n`. Callers that want a
nicer sentence use `fact` for the JSON and `text`/`textf` for the prose.
Do not build a templating system; two lanes and these five methods are
the whole mechanism.

## Error codes: one vocabulary, one home

`pub const ErrCode = enum` in `mcp.zig` — THE declaring home. Members
carry their facts (exhaustive switch, no `default`):

```zig
pub const ErrCode = enum {
    invalid_args,   // bad/missing tool arguments
    not_found,      // named pane/view/app/file/panel does not exist
    unavailable,    // subsystem absent (no GUI, helper not installed, fs not mounted)
    timeout,        // deadline expired and the operation did not settle
    refused,        // policy/permission refusal (--tools withheld, quarantine)
    conflict,       // valid request, state forbids it (already recording, busy)
    io_failed,      // underlying I/O or helper error
    unknown_tool,
    failed,         // catch-all; the migration default for untyped appErr sites

    pub fn retryable(self: ErrCode) bool {
        return switch (self) {
            .timeout, .unavailable, .io_failed => true,
            .invalid_args, .not_found, .refused, .conflict, .unknown_tool, .failed => false,
        };
    }
};
```

New helper `pub fn errRes(arena, code: ErrCode, msg: []const u8) ![]const u8`
produces the uniform error shape (text lane = the message).
`appErr(arena, msg)` is REWRITTEN as `errRes(arena, .failed, msg)` so its
~308 call sites keep compiling; module migration waves then upgrade the
high-value sites to typed codes (`not_found`, `invalid_args`, `timeout`,
`unavailable`) as they touch each module. `withheldMessage` refusals use
`.refused`; `callTool`'s Zig-error catch uses `.failed`; unknown-name
fallthroughs use `.unknown_tool`.

## Tool declarations: one table (Phase 2)

`TOOLS_JSON_RAW` (mcp.zig:1275-1390) + `mcpfilter.TOOL_META` are the same
vocabulary declared twice. Replace with ONE comptime table in a new
GTK-free module `src/ipc/mcp_tools.zig` (importable from both test
roots):

```zig
pub const ToolDef = struct {
    name: []const u8,
    group: mcpfilter.Group,
    mutates: bool,
    description: []const u8,
    input_schema: []const u8,          // raw JSON object text
    output_schema: ?[]const u8 = null, // raw JSON object text
};
pub const TOOLS = [_]ToolDef{ ... 112 entries ... };
```

- `TOOLS_JSON` is comptime-generated from `TOOLS` (same `%..._DEF%` token
  pass, same newline stripping).
- `mcpfilter.TOOL_META`/`lookup` derive from `TOOLS` (Meta stays as the
  lookup shape; the array is generated, not hand-maintained). The
  brace-depth `ObjectIter` filter may be kept or replaced by generating
  the filtered list straight from the table — prefer the table route and
  delete `ObjectIter` if nothing else needs it.
- The drift test mcp.zig:5821 becomes structurally impossible to fail;
  replace it with: every tool has a non-empty description, unique name,
  inputSchema with `properties`, and (once Phase 3 completes) an
  `output_schema`.
- `outputSchema` is emitted in tools/list only when present.

SHIPPED (wave 2). `src/ipc/mcp_tools.zig` holds `Group` (moved off
mcpfilter, which re-exports it), `ToolDef`, the 112-entry `TOOLS`, the
generated `TOOL_JSON`/`TOOLS_JSON`, and the comptime guards (unique
names, non-empty descriptions, no tool/group name collision, no control
byte in a description). Descriptions are stored DECODED and JSON-escaped
during generation; input/output schemas are raw JSON text emitted
verbatim. `mcpfilter.filterToolsJson(arena, policy)` rebuilds the
narrowed array from `TOOL_JSON`; `renderedToolsJson` filters first, then
substitutes the `%..._DEF%` tokens. Generation was proven byte-identical
to the deleted literal before the literal went away.

A tool's structured result is DECLARED on its entry:
`.output_schema = \\{"type":"object","properties":{...}}` (a multiline
literal, no escaping). It is no longer optional — three tests
(`mcp_tools.zig`'s two table tests and mcp.zig's
"every tool declaration is well-formed at the table level") refuse an
entry without one, so a new tool cannot ship JSON-in-text by omission.
Property sets several tools share are spliced comptime instead of
restated: `APP_STATE_PROPS` (appFacts), `SHOT_PROPS` (addShotFacts),
`INPUT_PROPS` (inputResult), `SCREEN_PROPS` (addScreenFacts).

## Text-lane style rules

- No JSON syntax, no braces, no escaped quotes.
- `key: value` lines for facts; bare strings; `true`/`false` for flags.
- One short header sentence is welcome ("opened view 12: Example Domain").
- Big payloads: a one-line header then the raw text.
- The behavioural hints that today live in result JSON (`reading_hint`,
  `current_view`, TRUST_NOTE, ...) move to the text lane ONLY where they
  are situational, or into the tool's `description` where they are
  static. TRUST_NOTE (page-authored data warning) stays: one text line on
  results that carry page content.
- Target: the text lane of a typical result is SHORTER than today's
  JSON-in-text rendering.

## Testing rules for the migration

- Unit tests assert through `mcp.expectToolResultShape` (plus
  `mcp.rpcToolResult` when the reply is a whole JSON-RPC envelope)
  rather than by matching escaped keys inside the text value. Every
  escaped-key assertion is gone from both mcp.zig's tests and
  smoke_mcp.zig; the one remaining escaped-quote run in smoke_mcp.zig is a panel
  DOCUMENT the fake presenter replies with, which is legitimately a
  JSON string on the wire.
- Every tool's result must round out to: parseable result JSON,
  a non-empty text block whose PROSE contains no `{`, and
  structuredContent matching its declared outputSchema (a test-side
  JSON-shape check, not a full validator). "Prose" is scoped:
  everything before the first payload divider (a `--- name ---` line,
  the convention every wave uses to introduce a payload) or the first
  blank line. Screen text, step transcripts, OCR reads, a11y trees and
  an app's own log legitimately contain braces; the rule stays strict on
  the result's own sentences, which is where JSON-in-text was the
  problem.
- `zig build test` and `zig build test-core` green after every wave;
  `zig build smoke-mcp` green at the end of Phase 3.

## Sequencing

1. Wave 1 (this doc's `Res` + `ErrCode` + `errRes` + rewritten
   `toolResult`/`appErr`/image helpers on top, unit tests). No tool
   behaviour changes yet beyond error results gaining structuredContent.
2. Wave 2: `mcp_tools.zig` table, generated tools/list + filter.
3. Wave 3: per-module migration (term -> web -> app -> core file/ui/
   panes/capabilities), sequential, each adding outputSchemas +
   updating its tests + its smoke stages. SHIPPED. Notes from the
   final wave (3d):
   - `list_terminals` no longer passes the GUI's `list` reply through
     verbatim: `listTerminalsResult` (pure, testable without a GUI)
     FLATTENS tabs into an addressable `terminals[]`, each entry
     carrying its own tab/window identity, so nothing is lost by the
     flattening and the text lane is one line per pane.
   - `file_read` splits by CONTENT: text content stays in the text
     lane behind `--- content ---` (duplicating a multi-megabyte read
     into structuredContent would serve no reader), while binary
     content is machine data and its base64 is a `base64` FACT, with
     the text lane reduced to the header plus one line saying where
     the bytes are. `binary` is a fact either way.
   - `capabilities` lost every `*_hint` prose field: the facts are
     structured and the explanations are the text lane's summary
     lines (the ones that are situational) or already live in a tool
     description (the ones that are static).
   - The caption-only `imageResult`/`imagesResult*` helpers are gone —
     the last caller (`screenshot_pane`) builds a `Res` and calls
     `finishWithImages`. `pngSize` moved to mcp.zig as the shared
     image-metadata read.
   - Panel failures are typed from their delivery PHASE first
     (`uiFailCode`), then from the vocabulary `relayFailure` speaks;
     addressing failures are typed by `uiResolveErr`. The pre-commit
     store-mutation verdict is prose in the message now
     (`mutation_may_have_applied=false, resend_safe=true`), spelled
     the same way every other panel failure spells it.
4. Wave 4: live client check against Claude Code / OpenCode. The full
   `zig build smoke-mcp` is green (all stages, web included).

## Smoke isolation (fixed in wave 3d)

`smoke_mcp.zig` spawns the server with `execv`, so the child inherits
this process's environment. The ui stage's "no origin daemon" probe
was answered by the DEVELOPER's real daemon because
`$SKETERM_MUX_SOCKET` — an ABSOLUTE path, immune to resetting
`$XDG_RUNTIME_DIR` — was never unset. `clearInheritedOrigin()` is now
the ONE declaring home for that list (`SKETERM_SOCKET`,
`SKETERM_PANE_ID`, `SKETERM_MUX_SOCKET`, `SKETERM_SESSION`,
`SKETERM_SESSION_ORIGIN_ID`), called by both the main run and
`webOnly`. The product was behaving correctly: an inherited exact
origin is the documented contract, so this was a test defect, not an
origin-discovery bug.

Later phases (profiles/contexts for headless views, web_close, network
policy, the Java SDK) build on this and are specced separately.
