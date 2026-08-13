#!/usr/bin/env bash

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fakebin="$work/bin"
mkdir -p "$fakebin"

cat > "$fakebin/pkg-config" <<'EOF'
#!/usr/bin/env bash
if [ "${INSTALL_TEST_PKG_CONFIG_FAIL:-0}" -eq 1 ]; then
    printf 'pkg-config must not run before makepkg\n' >&2
    exit 88
fi
printf '99.0\n'
EOF

cat > "$fakebin/makepkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$INSTALL_TEST_ARGV"
printf '%s\n' "$PWD" > "$INSTALL_TEST_CWD"
status=${INSTALL_TEST_STATUS:-0}
if [ "$status" -ne 0 ]; then
    printf 'fake makepkg failure\n' >&2
fi
exit "$status"
EOF

cat > "$fakebin/tic" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$fakebin/pkg-config" "$fakebin/makepkg" "$fakebin/tic"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_argv() {
    local expected="$work/expected-argv"
    printf '%s\0' "$@" > "$expected"
    cmp -s "$expected" "$INSTALL_TEST_ARGV" \
        || fail "makepkg argv did not match"
}

run_installer() {
    local output=$1
    shift
    PATH="$fakebin:$PATH" \
        INSTALL_TEST_ARGV="$work/actual-argv" \
        INSTALL_TEST_CWD="$work/actual-cwd" \
        "$here/install.sh" "$@" > "$output" 2>&1
}

INSTALL_TEST_ARGV="$work/actual-argv"
INSTALL_TEST_CWD="$work/actual-cwd"

run_installer "$work/help.out" --help
[[ "$(<"$work/help.out")" == *"./install.sh --no-install"* ]] \
    || fail "help omitted documented installer flags"
[[ "$(<"$work/help.out")" != *"set -euo pipefail"* ]] \
    || fail "help leaked installer implementation"

run_installer "$work/normal.out" \
    --gui-only --deps \
    --config "/tmp/config with spaces" '--literal=*' ''
assert_argv -sif --config "/tmp/config with spaces" '--literal=*' ''
[ "$(<"$INSTALL_TEST_CWD")" = "$here" ] \
    || fail "makepkg did not run from dist"

run_installer "$work/no-install.out" \
    --gui-only --no-install -- --help "two words" ''
assert_argv -sf --help "two words" ''

INSTALL_TEST_PKG_CONFIG_FAIL=1 run_installer "$work/missing-deps.out" --deps
assert_argv -sif

set +e
run_installer "$work/install-conflict.out" --no-install -- --install
status=$?
set -e
[ "$status" -eq 1 ] || fail "--no-install accepted a makepkg install option"
[[ "$(<"$work/install-conflict.out")" == *"--no-install cannot be combined"* ]] \
    || fail "conflicting makepkg install option failure was not explicit"

set +e
run_installer "$work/short-install-conflict.out" --no-install -i
status=$?
set -e
[ "$status" -eq 1 ] || fail "--no-install accepted makepkg -i"

set +e
PATH="$fakebin:$PATH" \
    INSTALL_TEST_ARGV="$work/actual-argv" \
    INSTALL_TEST_CWD="$work/actual-cwd" \
    INSTALL_TEST_STATUS=23 \
    "$here/install.sh" --gui-only > "$work/failure.out" 2>&1
status=$?
set -e
[ "$status" -eq 23 ] || fail "makepkg failure status was not preserved"

set +e
run_installer "$work/non-arch.out" --mux-only --nocheck
status=$?
set -e
[ "$status" -eq 1 ] || fail "non-Arch passthrough arguments were not rejected"
[[ "$(<"$work/non-arch.out")" == *"makepkg passthrough arguments require"* ]] \
    || fail "non-Arch passthrough failure was not explicit"

set +e
run_installer "$work/conflict.out" --mux-only --gui-only
status=$?
set -e
[ "$status" -eq 1 ] || fail "conflicting build modes were not rejected"

set +e
run_installer "$work/prefix.out" --prefix --no-install
status=$?
set -e
[ "$status" -eq 1 ] || fail "missing --prefix value was not rejected"

set +e
run_installer "$work/empty-prefix.out" --prefix ''
status=$?
set -e
[ "$status" -eq 1 ] || fail "empty --prefix value was not rejected"

set +e
run_installer "$work/arch-prefix.out" --gui-only --prefix "/unused prefix"
status=$?
set -e
[ "$status" -eq 1 ] || fail "Arch --prefix was not rejected"
[[ "$(<"$work/arch-prefix.out")" == *"--prefix applies only to plain installs"* ]] \
    || fail "Arch --prefix failure was not explicit"

fixture="$work/package-source"
mkdir -p "$fixture/dist" "$fixture/zig-out/bin" "$work/pkg"
cp "$here/install.sh" "$fixture/dist/install.sh"
ln -s "$root/data" "$fixture/data"
ln -s "$root/terminfo" "$fixture/terminfo"
ln -s "$root/LICENSE" "$fixture/LICENSE"
ln -s "$root/build.zig.zon" "$fixture/build.zig.zon"
for binary in sketerm sketerm-mux sketerm-mux-portable sketerm-webengine; do
    cp /bin/true "$fixture/zig-out/bin/$binary"
done

cat > "$fakebin/zig" <<'EOF'
#!/usr/bin/env bash
printf '<call>' >> "$INSTALL_TEST_ZIG_LOG"
printf ' <%s>' "$@" >> "$INSTALL_TEST_ZIG_LOG"
printf '\n' >> "$INSTALL_TEST_ZIG_LOG"
EOF

cat > "$fakebin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed'
EOF

cat > "$fakebin/dpkg" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --print-architecture) printf 'amd64\n' ;;
    -S) printf 'libc6:%s\n' "$2" ;;
    *) printf 'forbidden dpkg invocation: %s\n' "$*" >> "$INSTALL_TEST_FORBIDDEN"; exit 91 ;;
esac
EOF

cat > "$fakebin/ldd" <<'EOF'
#!/usr/bin/env bash
printf 'libc.so.6 => /lib/libc.so.6 (0x0)\n'
EOF

cat > "$fakebin/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --root-owner-group ] && [ "$2" = --build ] || exit 92
stagedir=$3
debfile=$4
[ -x "$stagedir/usr/bin/sketerm" ] || exit 93
[ -x "$stagedir/usr/bin/sketerm-mux" ] || exit 94
printf '%s\n' "$debfile" > "$INSTALL_TEST_DEB_LOG"
printf 'fake deb\n' > "$debfile"
EOF

for command_name in sudo apt-get; do
    cat > "$fakebin/$command_name" <<'EOF'
#!/usr/bin/env bash
if [ "${INSTALL_TEST_ALLOW_SUDO:-0}" -eq 1 ]; then
    exec "$@"
fi
printf 'forbidden privileged invocation: %s %s\n' "$0" "$*" >> "$INSTALL_TEST_FORBIDDEN"
exit 95
EOF
done

cat > "$work/no-makepkg.bash" <<'EOF'
command() {
    if [ "$#" -ge 2 ] && [ "$1" = -v ] && [ "$2" = makepkg ]; then
        return 1
    fi
    builtin command "$@"
}
EOF

cat > "$work/no-packager.bash" <<'EOF'
command() {
    if [ "$#" -ge 2 ] && [ "$1" = -v ]; then
        case "$2" in
            makepkg|dpkg-deb) return 1 ;;
        esac
    fi
    builtin command "$@"
}
EOF

chmod +x "$fixture/dist/install.sh" "$fakebin/zig" "$fakebin/dpkg-query" \
    "$fakebin/dpkg" "$fakebin/ldd" "$fakebin/dpkg-deb" \
    "$fakebin/sudo" "$fakebin/apt-get"

set +e
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_ZIG_LOG="$work/rejected-zig.log" \
    "$fixture/dist/install.sh" --gui-only --prefix "$work/plain-prefix" \
    > "$work/debian-prefix.out" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "dpkg --prefix was not rejected"
[[ "$(<"$work/debian-prefix.out")" == *"--prefix applies only to plain installs"* ]] \
    || fail "dpkg --prefix failure was not explicit"

set +e
BASH_ENV="$work/no-packager.bash" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_ZIG_LOG="$work/rejected-zig.log" \
    "$fixture/dist/install.sh" --mux-only --deps \
    > "$work/plain-deps.out" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "plain --deps was not rejected"
[[ "$(<"$work/plain-deps.out")" == *"--deps requires"* ]] \
    || fail "plain --deps failure was not explicit"

INSTALL_TEST_ZIG_LOG="$work/zig.log"
INSTALL_TEST_DEB_LOG="$work/deb.log"
INSTALL_TEST_FORBIDDEN="$work/forbidden.log"
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    INSTALL_TEST_DEB_LOG="$INSTALL_TEST_DEB_LOG" \
    INSTALL_TEST_FORBIDDEN="$INSTALL_TEST_FORBIDDEN" \
    "$fixture/dist/install.sh" --gui-only --deps --no-install \
    > "$work/debian.out" 2>&1

[ -f "$(<"$INSTALL_TEST_DEB_LOG")" ] \
    || fail "non-Arch --no-install did not build a package"
[ ! -e "$INSTALL_TEST_FORBIDDEN" ] \
    || fail "non-Arch --no-install attempted a privileged install"
[[ "$(<"$INSTALL_TEST_ZIG_LOG")" == *"<call> <build> <-Doptimize=ReleaseFast>"* ]] \
    || fail "non-Arch GUI build was not invoked"
[[ "$(<"$INSTALL_TEST_ZIG_LOG")" == *"<call> <build> <mux-portable> <-Doptimize=ReleaseFast>"* ]] \
    || fail "non-Arch portable daemon build was not invoked"
[[ "$(<"$work/debian.out")" == *"staged only, not installed"* ]] \
    || fail "non-Arch --no-install result was not reported"

mkdir -p "$work/plain-tmp" "$work/plain-prefix"
BASH_ENV="$work/no-packager.bash" \
    TMPDIR="$work/plain-tmp" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    "$fixture/dist/install.sh" --mux-only --no-install \
    > "$work/plain.out" 2>&1
[[ "$(<"$work/plain.out")" == *"staged in $work/plain-tmp/"* ]] \
    || fail "plain --no-install did not preserve and report its staging tree"
[[ "$(<"$work/plain.out")" == *"built: sketerm-mux (daemon), not installed"* ]] \
    || fail "plain --no-install claimed the daemon was installed"

BASH_ENV="$work/no-packager.bash" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_ALLOW_SUDO=1 \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    "$fixture/dist/install.sh" --mux-only --prefix "$work/plain-prefix" \
    > "$work/plain-prefix.out" 2>&1
[ -x "$work/plain-prefix/bin/sketerm-mux" ] \
    || fail "plain --prefix did not receive the installed daemon"

(
    export INSTALL_TEST_ZIG_LOG="$work/package-zig.log"
    startdir="$fixture/dist"
    pkgdir="$work/pkg"
    source "$here/PKGBUILD"
    PATH="$fakebin:$PATH" build
    PATH="$fakebin:$PATH" package
)

[[ "$(<"$work/package-zig.log")" == *"<call> <build> <web> <-Doptimize=ReleaseFast> <-Dcef-include=/usr/include/cef> <-Dcef-lib=/usr/lib/cef>"* ]] \
    || fail "PKGBUILD build() did not build sketerm-webengine"

[ -x "$work/pkg/usr/bin/sketerm-webengine" ] \
    || fail "PKGBUILD package() did not include sketerm-webengine"
cmp -s "$fixture/zig-out/bin/sketerm-webengine" \
    "$work/pkg/usr/bin/sketerm-webengine" \
    || fail "packaged sketerm-webengine did not come from the current build"

printf 'PASS: installer argument routing and package contents\n'
