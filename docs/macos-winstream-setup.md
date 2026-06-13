# Running remote macOS apps on a Mac host — full setup guide

This is the complete, copy-paste runbook for making **macOS apps
stream to a sketerm client** (the `winstream` / ScreenCaptureKit
backend). A macOS host has no forwardable display protocol, so the
`sketerm-mux` daemon captures each app window with ScreenCaptureKit
and ships pixels; the client renders them and sends keyboard/mouse
back. This works for Linux→Mac, Mac→Mac, and over every transport
(ssh / mux socket / roaming UDP).

It took a long debugging session to discover *why* the obvious setup
fails, so the steps below are not optional shortcuts — each one
defeats a specific macOS guardrail. The "Why each step exists"
section at the end explains them; if you just want it working,
follow Part 1–3 top to bottom.

Validated on Apple Silicon (M2), macOS 26.4, Zig 0.16, Homebrew GTK.

---

## TL;DR

```bash
# One-time:
#   1. Create a self-signed "sketerm-dev" Code Signing cert in
#      Keychain Access (GUI — see Step 2.1).
#   2. Deploy (build + sign + install GUI-session agent):
dist/deploy-macos.sh
#   3. Grant Screen Recording + Accessibility to sketerm-mux in
#      System Settings, then re-run step 2.

# Every rebuild after that — just:
dist/deploy-macos.sh
```

No re-granting on rebuilds: the grant is pinned to the cert, not the
binary hash.

---

## Part 0 — Prerequisites

```bash
brew install zig pkgconf gtk4 libadwaita adwaita-icon-theme \
             freetype harfbuzz libepoxy fribidi fontconfig
```

Confirm the daemon builds *with* the capture backend (native macOS
builds compile `src/winstream/sck_shim.m` and link ScreenCaptureKit
automatically):

```bash
zig build mux
otool -L zig-out/bin/sketerm-mux | grep ScreenCaptureKit   # must print a line
```

> `sketerm-mux-portable` and any Linux-built/cross-built daemon do
> **not** include capture (no macOS SDK to link against). Capture
> needs the native `zig build mux`.

You must be **logged into the Mac's GUI** (a real Aqua desktop
session, screen unlocked). A headless rack needs auto-login enabled.
WindowServer must be running.

---

## Part 1 — Create the code-signing identity (one-time, GUI)

This is the single step that can't be scripted (macOS requires GUI
authorization to trust a new signing cert). It takes 30 seconds.

**Step 2.1**
1. Open **Keychain Access**.
2. Menu **Keychain Access → Certificate Assistant → Create a
   Certificate…**
3. Set:
   - **Name:** `sketerm-dev`
   - **Identity Type:** **Self-Signed Root**
   - **Certificate Type:** **Code Signing**
4. Click **Create**, accept the defaults, **Done**.

A self-signed root you create is automatically trusted for your own
user, so `codesign -s sketerm-dev` will work. Verify:

```bash
security find-identity -v -p codesigning | grep sketerm-dev
```

You should see one line with a 40-hex SHA-1 and `"sketerm-dev"`.

---

## Part 2 — Deploy the daemon (repeatable)

From a **Terminal in your GUI session** (not over SSH — see Why #2):

```bash
dist/deploy-macos.sh
```

This script:
1. `zig build mux`
2. copies to `~/.local/bin/sketerm-mux` (override with
   `SKETERM_MUX_BIN`)
3. `codesign -f -s sketerm-dev --identifier dev.sker.sketerm-mux …`
   (override the identity with `SKETERM_SIGN_ID`)
4. writes `~/Library/LaunchAgents/dev.sker.sketerm-mux.plist`
5. `launchctl bootout` + `bootstrap gui/$UID` — loads the agent in
   **your** GUI session

The first run prints `✓ deployed — signed by 'sketerm-dev', agent
dev.sker.sketerm-mux running …`. The daemon is now alive but capture
is still denied until you grant (Part 3).

The daemon log is at `/tmp/sketerm-mux.log`. When permissions are
missing it logs the exact reason and the client shows a yellow
"grant Screen Recording" notice window — never a silent hang.

---

## Part 3 — Grant the TCC permissions (one-time per cert)

The first capture attempt registers `sketerm-mux` (disabled) in
System Settings; the first input attempt does the same for
Accessibility. Trigger them, then enable:

1. Start any app session so capture is attempted — e.g. attach a
   `winstream` client, or from a sketerm client run a GUI app inside
   a durable session on this host. (For a quick local trigger, see
   "Verifying" below.)
2. **System Settings → Privacy & Security → Screen Recording** →
   enable **sketerm-mux**.
3. **System Settings → Privacy & Security → Accessibility** →
   enable **sketerm-mux** (needed for keyboard/mouse/close).
4. Restart the daemon so Screen Recording takes effect (it only
   applies on relaunch):

   ```bash
   launchctl kickstart -k gui/$(id -u)/dev.sker.sketerm-mux
   ```

   (Re-running `dist/deploy-macos.sh` also does this.)

> **If an entry shows up but capture still says "declined":** it was
> registered against an *older* binary hash. Select sketerm-mux in
> the list, press the **“−”** button to remove it, then re-run
> `dist/deploy-macos.sh` and grant again. After the cert is in place
> this won't recur.

That's it. From now on, rebuild + redeploy is just
`dist/deploy-macos.sh` — no re-granting.

---

## Verifying it works

Spawn a throwaway capture target and watch a real window stream. A
minimal AppKit test app (window + an event counter) is the easiest
target — build one with `clang -fobjc-arc -framework AppKit`. Then
from a sketerm client, run that binary inside a durable session on
the host and confirm:

- a native window appears on the client showing the app's content,
- typing into it changes what's shown (counter increments),
- closing the client window closes the remote app.

Quick daemon-side sanity check (no client needed):

```bash
tail -f /tmp/sketerm-mux.log
# A healthy capture logs nothing. "declined TCCs" = grant missing;
# "CGS_REQUIRE_INIT" abort = not in the GUI session (see Why #1).
```

> Note: **system apps** (Calculator, TextEdit, …) carry launch
> constraints on modern macOS and exit instantly when spawned as a
> PTY child. Test with a third-party app or your own binary, launched
> from the session shell (not via `open`, which re-parents to
> launchd and escapes window tracking).

---

## The everyday dev loop

```bash
# edit code …
dist/deploy-macos.sh        # build, re-sign, reload agent — that's all
tail -f /tmp/sketerm-mux.log
```

Because the grant is pinned to the `sketerm-dev` cert and the script
re-signs every build with it, **rebuilds never need re-granting.**

To stop / remove:

```bash
launchctl bootout gui/$(id -u)/dev.sker.sketerm-mux
rm ~/Library/LaunchAgents/dev.sker.sketerm-mux.plist
```

---

## Why each step exists (the three guardrails)

If you skip a step, here's what breaks and why.

**1. The daemon must run in the Aqua GUI session.**
ScreenCaptureKit's `SCContentFilter` makes *in-process* WindowServer
(SkyLight) calls — `SLSGetDisplaysWithRect`. A process with no
WindowServer connection aborts with:

```
Assertion failed: (did_initialize), function CGS_REQUIRE_INIT
```

Two things are needed: (a) the daemon self-promotes to a UIElement
app (`NSApplicationActivationPolicyAccessory`) to establish the
connection — done in code, no Dock icon; and (b) it must actually be
*in* the GUI session. A LaunchAgent **bootstrapped over SSH lands in
the wrong audit session** and still can't reach WindowServer — which
is why `dist/deploy-macos.sh` must run from a Terminal in your GUI
session.

**2. It must be a LaunchAgent, not a shell-launched process.**
TCC attributes a permission request to the "responsible process".
Launch the daemon from a terminal and TCC checks the *terminal app's*
Screen Recording grant (which it doesn't have) → denied. As a
`launchd` agent, the responsible process is `sketerm-mux` itself, so
its own grant applies. (Backgrounding with `nohup … &` does **not**
fix this — still attributed to the terminal.)

**3. Sign with a stable cert, or re-grant every build.**
TCC pins a grant to the binary's code signature. Zig binaries are
*ad-hoc* signed — the hash (cdhash) changes on every rebuild, so the
grant goes stale and macOS silently denies the new binary. Signing
with a self-signed cert records the grant against the **certificate**
instead; any rebuild re-signed with the same cert satisfies it. This
is why Part 1 exists and why the deploy script always re-signs.

> Bonus gotcha we hit: you can't fix a stale grant with `tccutil`
> (it only targets bundle IDs, not bare-binary path entries) and you
> can't edit `TCC.db` directly (SIP-protected). The only path is the
> System Settings **−**-then-re-grant, which Part 3 covers — and once
> the cert is in place you never need it again.

---

## Troubleshooting quick reference

| Symptom (in `/tmp/sketerm-mux.log` or client) | Cause | Fix |
|---|---|---|
| Yellow "grant Screen Recording" notice window | Screen Recording not granted (or stale hash) | Part 3; remove stale entry if needed |
| `shareable-content fetch failed: …declined TCCs` | same as above | same |
| `Assertion …CGS_REQUIRE_INIT` abort | daemon not in GUI session | run `dist/deploy-macos.sh` from a GUI Terminal, not SSH |
| `input dropped: Accessibility not granted` | Accessibility off | Part 3, Accessibility toggle |
| Capture worked yesterday, denied after rebuild | ad-hoc rebuild changed the hash | you skipped signing — use `dist/deploy-macos.sh` (signs every build) |
| `codesign … no identity found` | cert missing | Part 1 |
| App session exits instantly, one frame | system app launch constraints | use a third-party app / your own binary |
| App window never appears | launched via `open` (re-parented) | launch from the session shell directly |

See also `docs/REMOTE.md` ("Remote macOS apps") and
`docs/macos.md` for the broader macOS port status.
