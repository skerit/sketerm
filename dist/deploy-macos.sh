#!/bin/bash
# Build, sign, and install sketerm-mux as a GUI-session LaunchAgent
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
case "$DEST" in
    /*) ;;
    *) DEST="$(pwd)/$DEST" ;;
esac
LABEL="dev.sker.sketerm-mux"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
LOADED=0
ACTIVE_DEST=""
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    LOADED=1
    ACTIVE_DEST="$(launchctl print "gui/$UID_NUM/$LABEL" | awk -F' = ' '/^[[:space:]]*program = / && !seen {value=$2; seen=1} END {print value}')"
    if [ -z "$ACTIVE_DEST" ]; then
        echo "  x cannot determine the loaded daemon path; refusing an unsafe replacement" >&2
        exit 1
    fi
fi

cd "$(dirname "$0")/.."

echo "› building sketerm-mux"
zig build mux

echo "› staging $DEST"
mkdir -p "$(dirname "$DEST")"
STAGED="${DEST}.new.$$"
ACTIVE_STAGED=""
PLIST_STAGED=""
trap 'rm -f "$STAGED"; [ -z "$ACTIVE_STAGED" ] || rm -f "$ACTIVE_STAGED"; [ -z "$PLIST_STAGED" ] || rm -f "$PLIST_STAGED"' EXIT
cp zig-out/bin/sketerm-mux "$STAGED"

echo "› signing with '$ID'"
if ! codesign -f -s "$ID" --identifier "$LABEL" "$STAGED" 2>/dev/null; then
    echo "  ✗ signing failed — is the '$ID' code-signing identity in your"
    echo "    login keychain? Create it once via Keychain Access →"
    echo "    Certificate Assistant → Create a Certificate (Self-Signed"
    echo "    Root, Code Signing). See docs/REMOTE.md." >&2
    exit 1
fi
mv -f "$STAGED" "$DEST"

# launchd keeps loaded ProgramArguments in memory. If the requested path
# changed, update the active path too so a natural restart runs this build;
# the plist below makes the requested path authoritative after the next login.
if [ "$LOADED" -eq 1 ] && [ "$ACTIVE_DEST" != "$DEST" ]; then
    echo "› updating loaded agent path $ACTIVE_DEST"
    mkdir -p "$(dirname "$ACTIVE_DEST")"
    ACTIVE_STAGED="${ACTIVE_DEST}.new.$$"
    cp "$DEST" "$ACTIVE_STAGED"
    mv -f "$ACTIVE_STAGED" "$ACTIVE_DEST"
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
PLIST_STAGED="${PLIST}.new.$$"
DEST_XML="$(printf '%s' "$DEST" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
cat > "$PLIST_STAGED" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST_XML</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/sketerm-mux.log</string>
  <key>StandardErrorPath</key><string>/tmp/sketerm-mux.log</string>
</dict>
</plist>
PLISTEOF
plutil -lint "$PLIST_STAGED" >/dev/null
mv -f "$PLIST_STAGED" "$PLIST"
PLIST_STAGED=""

if [ "$LOADED" -eq 1 ]; then
    echo "› existing daemon preserved (new binary applies after its natural exit/reboot)"
else
    echo "› loading agent in your GUI session"
    launchctl bootstrap "gui/$UID_NUM" "$PLIST"
fi

# NB: no `awk … exit` here — closing the pipe early makes codesign take
# SIGPIPE, which `set -o pipefail` turns into a spurious 141 exit AFTER a
# successful reload (confusing when run via the GUI runner). Read it all.
AUTH=$(codesign -dvv "$DEST" 2>&1 | awk -F= '/Authority/ && !seen {print $2; seen=1}')
echo "✓ deployed — signed by '${AUTH:-?}', agent $LABEL running in gui/$UID_NUM"
echo "  log: /tmp/sketerm-mux.log"
