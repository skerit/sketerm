#!/usr/bin/env bash
# A real daemon under a real user manager: a session whose program the kernel
# OOM-kills must cost only that program. Needs systemd --user, so it is run by
# hand, not from `zig build`. Usage: dist/test-mux-oom-unit.sh [sketerm-mux] [sketerm]

set -euo pipefail

root=$(readlink -f "$(dirname "$(readlink -f "$0")")/..")
mux=$(readlink -f "${1:-$root/zig-out/dev-bin/sketerm-mux}")
cli=$(readlink -f "${2:-$root/zig-out/dev-bin/sketerm}")
uid=$(id -u)
# The tests below repoint XDG_RUNTIME_DIR; the user manager stays at the real one.
real_rt="/run/user/$uid"
sys() { XDG_RUNTIME_DIR=$real_rt systemctl --user "$@"; }

if ! systemctl --user is-system-running >/dev/null 2>&1 &&
    ! systemctl --user show -p Version >/dev/null 2>&1; then
    echo "SKIP: no systemd user manager"
    exit 0
fi

# Short: sockaddr_un caps the socket path.
work=$(mktemp -d /tmp/skoom.XXXXXX)
launcher="skoom-launcher-$$"
pid=
cleanup() {
    sys stop "$launcher.service" 2>/dev/null || true
    # The scope first: it holds the workers, which outlive a killed broker.
    if [ -n "$pid" ]; then sys stop "sketerm-mux-$pid.scope" 2>/dev/null || true; fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$work/run" "$work/state" "$work/config"
chmod 700 "$work/run"
export XDG_RUNTIME_DIR="$work/run" XDG_STATE_HOME="$work/state" XDG_CONFIG_HOME="$work/config"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus"
unset SKETERM_MUX_SOCKET SKETERM_MUX_LIFETIME_FD

# The shape KDE gives a launched GUI: a transient service that outlives its
# main process through ExitType=cgroup, on the default OOMPolicy=stop.
XDG_RUNTIME_DIR=$real_rt systemd-run --user --quiet --unit="$launcher" --slice=app.slice \
    -p Type=simple -p ExitType=cgroup -p CollectMode=inactive-or-failed \
    --setenv=XDG_RUNTIME_DIR="$work/run" --setenv=XDG_STATE_HOME="$work/state" \
    --setenv=XDG_CONFIG_HOME="$work/config" --setenv=DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    --setenv=PATH="$PATH" \
    /bin/sh -c "\"$mux\" & sleep 600"

for _ in $(seq 100); do
    rec=$(ls "$work/state/sketerm/mux-daemons/" 2>/dev/null | head -1 || true)
    [ -n "$rec" ] && [ -S "$work/run/sketerm/mux.sock" ] && break
    sleep 0.1
done
[ -n "${rec:-}" ] || fail "daemon never registered"
pid=${rec%.json}
sleep 0.3

cgroup=$(tail -1 "/proc/$pid/cgroup")
case $cgroup in
*/sketerm-mux-"$pid".scope) ;;
*) fail "daemon stayed in $cgroup" ;;
esac
scope="sketerm-mux-$pid.scope"
[ "$(sys show -p OOMPolicy --value "$scope")" = continue ] || fail "$scope is not OOMPolicy=continue"
echo "ok: daemon $pid moved to $scope with OOMPolicy=continue"

"$cli" mux spawn survivor sleep 600 >/dev/null
sys set-property --runtime "$scope" MemoryMax=96M MemorySwapMax=0
cat >"$work/hog.py" <<'EOF'
x = []
while True:
    x.append(bytearray(b"x" * (8 << 20)))
EOF
"$cli" mux spawn hog python3 "$work/hog.py" >/dev/null

scope_dir=/sys/fs/cgroup$(echo "$cgroup" | sed 's/^0:://')
for _ in $(seq 100); do
    kills=$(awk '$1=="oom_kill"{print $2}' "$scope_dir/memory.events" 2>/dev/null || echo 0)
    [ "${kills:-0}" -gt 0 ] && break
    sleep 0.1
done
[ "${kills:-0}" -gt 0 ] || fail "the kernel never OOM-killed the hog"
sleep 1

kill -0 "$pid" 2>/dev/null || fail "daemon died after an OOM kill in one session"
[ "$(sys is-active "$scope" || true)" = active ] || fail "$scope stopped"
[ "$(sys is-active "$launcher.service" || true)" = active ] || fail "launcher unit stopped"
"$cli" mux list | grep -q survivor || fail "the other session is gone"
echo "ok: oom_kill=$kills cost one program; daemon, other session and launcher all live"
