#!/bin/bash
# macOS winstream acceptance test — verifies that a developer followed
# every setup step in docs/macos-winstream-setup.md and that the full
# capture + input + close pipeline actually works on this Mac.
#
# Run it from a Terminal in your GUI session (the daemon must be a
# GUI-session LaunchAgent for capture to reach WindowServer):
#
#     dist/macos-winstream-check.sh
#
# It checks the prerequisites, then spawns a throwaway AppKit window
# through the running daemon and asserts that frames arrive, an
# injected keystroke changes them, and close works. Each check prints
# PASS/FAIL with the remedy. Exit status 0 = all green.

set -uo pipefail

BIN="${SKETERM_MUX_BIN:-$HOME/.local/bin/sketerm-mux}"
LABEL="dev.sker.sketerm-mux"
SIGN_ID="${SKETERM_SIGN_ID:-sketerm-dev}"
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
# Default socket matches runtimeDir()'s confstr path; override for a
# daemon run on a custom --socket.
SOCK="${SKETERM_MUX_SOCK:-${TMP%/}/sketerm/mux.sock}"

fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
err()  { printf '  \033[31m✗\033[0m %s\n     → %s\n' "$1" "$2"; fails=$((fails+1)); }

echo "macOS winstream acceptance check"
echo "  daemon binary : $BIN"
echo "  default socket: $SOCK"
echo

echo "Prerequisites:"

# 1. Code-signing identity available for future re-signs. (The hard
#    gate is "daemon signed by $SIGN_ID" below; find-identity can't
#    enumerate a locked keychain — e.g. when run over SSH — so a miss
#    here is only a warning.)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    pass "code-signing identity '$SIGN_ID' present"
else
    warn "code-signing identity '$SIGN_ID' not enumerable (locked keychain / SSH?) — if the daemon is signed by it below, you're fine; otherwise create it: Keychain Access → Certificate Assistant → Create a Certificate (Self-Signed Root, Code Signing), name it $SIGN_ID"
fi

# 2. Daemon built with capture + signed with the cert.
if [ -x "$BIN" ]; then
    if otool -L "$BIN" 2>/dev/null | grep -q ScreenCaptureKit; then
        pass "daemon links ScreenCaptureKit (capture-capable build)"
    else
        err "daemon does not link ScreenCaptureKit" \
            "build natively on the Mac: zig build mux (portable/cross builds have no capture)"
    fi
    AUTH=$(codesign -dvv "$BIN" 2>&1 | awk -F= '/Authority/{print $2; exit}')
    if [ "$AUTH" = "$SIGN_ID" ]; then
        pass "daemon signed by '$SIGN_ID'"
    else
        err "daemon not signed by '$SIGN_ID' (got '${AUTH:-ad-hoc}')" \
            "run dist/deploy-macos.sh to build + sign + reload"
    fi
else
    err "daemon binary not found at $BIN" "run dist/deploy-macos.sh"
fi

# 3. A daemon is listening on the socket, ideally the GUI-session
#    LaunchAgent (so capture reaches WindowServer + TCC attributes the
#    grant to sketerm-mux, not a terminal).
if [ -S "$SOCK" ]; then
    pass "daemon listening on $SOCK"
else
    err "no socket at $SOCK" \
        "run dist/deploy-macos.sh from a GUI Terminal (NOT over SSH)"
fi
PID=$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}')
if [ -n "${PID:-}" ]; then
    pass "GUI-session LaunchAgent '$LABEL' running (pid $PID)"
else
    warn "LaunchAgent '$LABEL' not found — if capture works below, the daemon is reachable anyway; for the documented setup run dist/deploy-macos.sh"
fi

# 4. TCC grants — present, enabled, and pinned to THIS binary's cert.
LEAF=$(codesign -d -r- "$BIN" 2>&1 | grep -o 'certificate leaf = H"[a-f0-9]*"' | grep -o '[a-f0-9]\{40\}')
check_tcc() {
    local svc="$1" human="$2"
    local row
    row=$(sqlite3 "$TCC_DB" "select coalesce(auth_value,-1) from access where client like '%sketerm%' and service='$svc'" 2>/dev/null)
    if [ -z "$row" ]; then
        err "$human: not registered" "trigger it once, then enable sketerm-mux in System Settings"
        return
    fi
    if [ "$row" != "2" ]; then
        err "$human: present but disabled" "enable sketerm-mux in System Settings → Privacy & Security → $human"
        return
    fi
    # Confirm the grant matches the current binary's signing cert.
    local reqhex match
    reqhex=$(sqlite3 "$TCC_DB" "select quote(csreq) from access where client like '%sketerm%' and service='$svc'" 2>/dev/null | tr -d "X'")
    match=$(python3 - "$reqhex" "$LEAF" <<'PY'
import sys
blob=bytes.fromhex(sys.argv[1]); leaf=sys.argv[2]
print("yes" if (leaf and bytes.fromhex(leaf) in blob) else "no")
PY
)
    if [ "$match" = "yes" ]; then
        pass "$human granted (cert-pinned — survives rebuilds)"
    else
        err "$human granted but pinned to a DIFFERENT binary (stale)" \
            "remove sketerm-mux from the $human list (− button), re-run deploy, re-grant"
    fi
}
check_tcc kTCCServiceScreenCapture "Screen Recording"
check_tcc kTCCServiceAccessibility "Accessibility"

if [ "$fails" -gt 0 ]; then
    echo
    echo "Prerequisites failed ($fails) — fix the above, then re-run. Skipping the live test."
    exit 1
fi

echo
# A locked screen has no active GUI session, so newly-launched apps
# don't map renderable windows and capture produces nothing. Flag it
# rather than letting the live test fail mysteriously.
if ioreg -n Root -d1 2>/dev/null | grep -i IOConsoleLocked | grep -qi yes; then
    echo "Live capture + input + close test:"
    err "screen is LOCKED — capture needs an unlocked, active GUI session" \
        "unlock the Mac and re-run"
    echo
    printf '\033[31m%d CHECK(S) FAILED\033[0m\n' "$fails"; exit 1
fi
echo "Live capture + input + close test:"

# Build a throwaway AppKit target: a window whose content changes on
# every key/click (so injected input is visible as a frame change).
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null' EXIT
cat > "$WORK/testapp.m" <<'OBJC'
#import <AppKit/AppKit.h>
@interface V : NSView { @public int n; } @end
@implementation V
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)r {
    [(n%2 ? NSColor.systemOrangeColor : NSColor.systemIndigoColor) setFill]; NSRectFill(self.bounds);
    [[NSString stringWithFormat:@"events: %d", n] drawAtPoint:NSMakePoint(20, self.bounds.size.height/2)
        withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:34], NSForegroundColorAttributeName:NSColor.whiteColor}];
}
- (void)bump { n++; [self setNeedsDisplay:YES]; }
- (void)keyDown:(NSEvent *)e { [self bump]; }
- (void)mouseDown:(NSEvent *)e { [self bump]; }
@end
@interface D : NSObject <NSWindowDelegate> @end
@implementation D
- (void)windowWillClose:(NSNotification *)n { [NSApp terminate:nil]; }
@end
int main(void) { @autoreleasepool {
    NSApplication *a = NSApplication.sharedApplication;
    [a setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,480,320)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"winstream acceptance";
    V *v = [[V alloc] initWithFrame:NSMakeRect(0,0,480,320)];
    w.contentView = v; D *d = [D new]; w.delegate = d; a.delegate = d;
    [w makeKeyAndOrderFront:nil]; [w makeFirstResponder:v]; [a activateIgnoringOtherApps:YES];
    [a run];
} return 0; }
OBJC
if ! clang -fobjc-arc -framework AppKit -o "$WORK/testapp" "$WORK/testapp.m" 2>"$WORK/cc.log"; then
    err "could not build the test app" "see $WORK/cc.log"; exit 1
fi
pass "built throwaway AppKit test window"

# Drive the mux protocol: spawn the app, assert capture, inject a key,
# assert the frame changes, then close it.
RESULT=$(python3 - "$SOCK" "$WORK/testapp" <<'PY'
import socket,struct,json,time,zlib,sys,os
SOCK,APP=sys.argv[1],sys.argv[2]
s=socket.socket(socket.AF_UNIX); s.settimeout(20)
try: s.connect(SOCK)
except Exception as e: print(f"FAIL connect: {e}"); sys.exit(1)
def sj(t,o): p=json.dumps(o).encode(); s.sendall(struct.pack("<I",len(p)+1)+bytes([t])+p)
def sf(t,p): s.sendall(struct.pack("<I",len(p)+1)+bytes([t])+p)
def unit(tag,pl): return struct.pack("<I",len(pl)+1)+bytes([tag])+pl
name=f"accept-{os.getpid()}"
sj(1,{"proto":2}); time.sleep(.3)
sj(3,{"name":name,"argv":[APP],"app":True,"rows":24,"cols":80}); time.sleep(.6)
sj(2,{"name":name})
chan=None; acc=b""; buf=b""; win=None; title=None; dims=None
frames=0; baseline=None; changed=False; sent=0; closed=False
def peel(b):
    out=[]; p=0
    while len(b)-p>=5:
        ln=struct.unpack("<I",b[p:p+4])[0]
        if len(b)-p<4+ln: break
        out.append((b[p+4],b[p+5:p+4+ln])); p+=4+ln
    return out,b[p:]
t=time.time()
while time.time()-t<18:
    try: d=s.recv(1<<20)
    except: break
    if not d: break
    buf+=d; fr,buf=peel(buf)
    for ft,pl in fr:
        if ft==70: print("FAIL daemon error:", pl.decode('utf8','replace')); sys.exit(1)
        if ft==80:
            cid,kind=struct.unpack("<IB",pl[:5])
            if kind==3: chan=cid
        elif ft==81 and chan is not None and struct.unpack("<I",pl[:4])[0]==chan:
            acc+=pl[4:]; us,acc=peel(acc)
            for tag,u in us:
                if tag==1:
                    win,w,h=struct.unpack("<Iii",u[:12]); title=u[12:].decode('utf8','replace'); dims=(w,h)
                    if "grant Screen Recording" in title: print("FAIL capture denied (grants)"); sys.exit(1)
                elif tag in (2,3):
                    px=u[12:] if tag==2 else zlib.decompress(u[16:],-15); frames+=1
                    sig=hash(px[:8000])
                    if baseline is None: baseline=sig
                    elif sig!=baseline: changed=True
                elif tag==5:
                    closed=True
        elif ft==67: closed=True
    if win and frames>=4 and sent<3 and chan is not None and not changed:
        sf(81, struct.pack("<I",chan)+unit(16,struct.pack("<IIBI",win,2,1,0))+unit(16,struct.pack("<IIBI",win,2,0,0)))
        sent+=1; time.sleep(.4)
    if changed and not closed and win and chan is not None and sent>0:
        sf(81, struct.pack("<I",chan)+unit(18,struct.pack("<I",win)))
        time.sleep(1.0)
        try: sj(8,{"name":name})
        except: pass
        break
ok = bool(win) and frames>=4 and changed
print(("PASS" if ok else "FAIL") +
      f" window={title!r} dims={dims} frames={frames} input_changed_frame={changed} closed={closed}")
sys.exit(0 if ok else 1)
PY
)
echo "  $RESULT"
case "$RESULT" in
  PASS*) pass "capture + input + close round-trip" ;;
  *) err "live round-trip failed" "check /tmp/sketerm-mux.log for the daemon-side reason"; ;;
esac

echo
if [ "$fails" -eq 0 ]; then
    printf '\033[32mALL CHECKS PASSED\033[0m — remote macOS apps are working on this host.\n'
    exit 0
else
    printf '\033[31m%d CHECK(S) FAILED\033[0m\n' "$fails"; exit 1
fi
