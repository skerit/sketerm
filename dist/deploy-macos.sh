#!/bin/bash
# Build, sign, and (re)launch sketerm-mux as a GUI-session LaunchAgent
# on macOS — the deployment the ScreenCaptureKit window-stream backend
# needs. Three constraints make this non-obvious (all learned the hard
# way; see docs/REMOTE.md "Remote macOS apps"):
#
#   1. Capture (SCContentFilter) makes in-process WindowServer calls,
#      so the daemon must run INSIDE the Aqua GUI session. A LaunchAgent
#      bootstrapped over SSH lands in the wrong session and aborts with
#      a CGS_REQUIRE_INIT assertion — this script bootstraps it from
#      your own session.
#   2. TCC attributes a grant to the "responsible process". Launched
#      from a shell, that's the terminal app (no grant → denied); as a
#      launchd LaunchAgent, it's sketerm-mux itself. So it MUST be an
#      agent, not a backgrounded shell job.
#   3. TCC pins the grant to the binary's code signature. Ad-hoc builds
#      change hash every rebuild → re-grant every time. Signing with a
#      stable self-signed cert pins the CERT instead, so rebuilds keep
#      the grant. Create the cert once (docs/REMOTE.md), then this
#      script re-signs every build with it.
#
# RUN FROM A TERMINAL IN YOUR GUI SESSION (codesign needs your unlocked
# login keychain; the agent must load in your audit session).
set -euo pipefail

ID="${SKETERM_SIGN_ID:-sketerm-dev}"          # self-signed code-signing identity
DEST="${SKETERM_MUX_BIN:-$HOME/.local/bin/sketerm-mux}"
LABEL="dev.sker.sketerm-mux"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

cd "$(dirname "$0")/.."

echo "› building sketerm-mux"
zig build mux

echo "› staging $DEST"
mkdir -p "$(dirname "$DEST")"
cp zig-out/bin/sketerm-mux "$DEST"

echo "› signing with '$ID'"
if ! codesign -f -s "$ID" --identifier "$LABEL" "$DEST" 2>/dev/null; then
    echo "  ✗ signing failed — is the '$ID' code-signing identity in your"
    echo "    login keychain? Create it once via Keychain Access →"
    echo "    Certificate Assistant → Create a Certificate (Self-Signed"
    echo "    Root, Code Signing). See docs/REMOTE.md." >&2
    exit 1
fi

# A remote client reaches this daemon via `ssh <host> sketerm-mux
# --proxy`, which sshd runs as `zsh -c …` — that sources ONLY ~/.zshenv,
# not ~/.zprofile/.zshrc. So $DEST's dir must be on PATH there, or the
# client fails with "command not found: sketerm-mux". Ensure it.
BINDIR="$(dirname "$DEST")"
ZSHENV="$HOME/.zshenv"
REL="${BINDIR#"$HOME"/}"
[ "$REL" != "$BINDIR" ] && PATHENTRY="\$HOME/$REL" || PATHENTRY="$BINDIR"
if ! grep -qsF "$PATHENTRY" "$ZSHENV"; then
    printf 'export PATH="%s:$PATH"  # sketerm-mux for non-interactive ssh (--proxy)\n' "$PATHENTRY" >> "$ZSHENV"
    echo "› added $PATHENTRY to ~/.zshenv (so 'ssh … sketerm-mux --proxy' resolves it)"
fi

# Generate the agent plist (idempotent — path may differ per machine).
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/sketerm-mux.log</string>
  <key>StandardErrorPath</key><string>/tmp/sketerm-mux.log</string>
</dict>
</plist>
PLISTEOF

echo "› (re)loading agent in your GUI session"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

# NB: no `awk … exit` here — closing the pipe early makes codesign take
# SIGPIPE, which `set -o pipefail` turns into a spurious 141 exit AFTER a
# successful reload (confusing when run via the GUI runner). Read it all.
AUTH=$(codesign -dvv "$DEST" 2>&1 | awk -F= '/Authority/ && !seen {print $2; seen=1}')
echo "✓ deployed — signed by '${AUTH:-?}', agent $LABEL running in gui/$UID_NUM"
echo "  log: /tmp/sketerm-mux.log"
