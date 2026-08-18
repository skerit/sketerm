#!/usr/bin/env bash

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fakebin="$work/bin"
mkdir -p "$fakebin"
real_dpkg_deb=$(command -v dpkg-deb || true)

cat > "$fakebin/pkg-config" <<'EOF'
#!/usr/bin/env bash
if [ -n "${INSTALL_TEST_PKG_CONFIG_LOG:-}" ]; then
    printf '<pkg-config>' >> "$INSTALL_TEST_PKG_CONFIG_LOG"
    printf ' <%s>' "$@" >> "$INSTALL_TEST_PKG_CONFIG_LOG"
    printf '\n' >> "$INSTALL_TEST_PKG_CONFIG_LOG"
fi
if [ "${INSTALL_TEST_PKG_CONFIG_FAIL:-0}" -eq 1 ] \
        && [ ! -e "${INSTALL_TEST_DEPS_READY:-/no/such/file}" ]; then
    printf 'missing development package\n' >&2
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

cat > "$fakebin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fakebin/zig" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = version ] || exit 89
printf '%s\n' "${INSTALL_TEST_ZIG_VERSION:-0.16.0}"
EOF

chmod +x "$fakebin/pkg-config" "$fakebin/makepkg" "$fakebin/tic" \
    "$fakebin/pacman" "$fakebin/zig"

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

INSTALL_TEST_PKG_CONFIG_FAIL=1 run_installer "$work/help.out" --help
[[ "$(<"$work/help.out")" == *"./install.sh --no-install"* ]] \
    || fail "help omitted documented installer flags"
[[ "$(<"$work/help.out")" != *"set -euo pipefail"* ]] \
    || fail "help leaked installer implementation"

run_installer "$work/normal.out" \
    --gui-only --deps \
    -cLm --key "/tmp/installer-dir pfile" '--key=literal*'
assert_argv -sif -cLm --key "/tmp/installer-dir pfile" '--key=literal*'
[ "$(<"$INSTALL_TEST_CWD")" = "$here" ] \
    || fail "makepkg did not run from dist"

run_installer "$work/no-install.out" \
    --gui-only --no-install -- -A --nocheck --key=/tmp/installer-dir-pfile
assert_argv -sf -A --nocheck --key=/tmp/installer-dir-pfile

INSTALL_TEST_PKG_CONFIG_FAIL=1 run_installer "$work/missing-deps.out" --deps
assert_argv -sif

set +e
INSTALL_TEST_ZIG_VERSION=0.15.2 run_installer "$work/arch-bad-zig.out" --no-install
status=$?
set -e
[ "$status" -eq 1 ] || fail "Arch path accepted Zig 0.15.2"
[[ "$(<"$work/arch-bad-zig.out")" == *"requires Zig 0.16.x"* ]] \
    || fail "Arch path gave no Zig 0.16.x guidance"

for rejected in -i -cif --install --inst --insta --instal --needed --asdeps \
                -D -D/tmp/installer-dir -cD/tmp/installer-dir -p -pfile \
                --d=/tmp/build --di=/tmp/build --dir=/tmp/build; do
    set +e
    run_installer "$work/rejected.out" --no-install -- "$rejected"
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail "unsafe makepkg option was accepted: $rejected"
    case "$rejected" in
        *D*|-p*|--d*)
            [[ "$(<"$work/rejected.out")" == *"source-relocating makepkg options"* ]] \
                || fail "relocating option had the wrong failure: $rejected" ;;
    esac
done

for rejected in -o -R -S --packagelist --printsrcinfo --verifysource \
                --config=/tmp/makepkg.conf 'CFLAGS=-pipe'; do
    set +e
    run_installer "$work/rejected.out" -- "$rejected"
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail "non-building makepkg argument was accepted: $rejected"
done

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
cp "$here/stage.sh" "$fixture/dist/stage.sh"
ln -s "$root/data" "$fixture/data"
ln -s "$root/terminfo" "$fixture/terminfo"
ln -s "$root/LICENSE" "$fixture/LICENSE"
ln -s "$root/build.zig.zon" "$fixture/build.zig.zon"
[ "$(grep -m1 minimum_zig_version "$root/build.zig.zon")" = \
    '    .minimum_zig_version = "0.16.0",' ] \
    || fail "build.zig.zon does not require Zig 0.16.0"
for binary in sketerm sketerm-mux sketerm-mux-portable sketerm-webengine; do
    cp /bin/true "$fixture/zig-out/bin/$binary"
done

cat > "$fakebin/zig" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
    printf '%s\n' "${INSTALL_TEST_ZIG_VERSION:-0.16.0}"
    exit 0
fi
if [ "${INSTALL_TEST_ZIG_PROBE_FRIBIDI:-0}" -eq 1 ] \
        && [ "${1:-}" = build ]; then
    pkg-config --cflags-only-I fribidi >/dev/null
fi
printf '<call>' >> "$INSTALL_TEST_ZIG_LOG"
printf ' <%s>' "$@" >> "$INSTALL_TEST_ZIG_LOG"
printf '\n' >> "$INSTALL_TEST_ZIG_LOG"
EOF

cat > "$fakebin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [ "${INSTALL_TEST_DEPS_MISSING:-0}" -eq 1 ] \
        && [ ! -e "${INSTALL_TEST_DEPS_READY:-/no/such/file}" ]; then
    exit 1
fi
printf 'install ok installed'
EOF

cat > "$fakebin/dpkg" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --print-architecture) printf '%s\n' "${INSTALL_TEST_DPKG_ARCH:-amd64}" ;;
    -S)
        case "$2" in
            */libalpha.so) printf 'alpha-runtime:%s\n' "$2" ;;
            */libbeta.so) printf 'beta-runtime:%s\n' "$2" ;;
            */libdelta.so) printf 'delta-runtime:%s\n' "$2" ;;
            */libepsilon.so) printf 'epsilon-runtime:%s\n' "$2" ;;
            */libgamma.so) printf 'gamma-runtime:%s\n' "$2" ;;
            *) exit 1 ;;
        esac ;;
    *) printf 'forbidden dpkg invocation: %s\n' "$*" >> "$INSTALL_TEST_FORBIDDEN"; exit 91 ;;
esac
EOF

cat > "$fakebin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -m ]; then
    printf '%s\n' "${INSTALL_TEST_UNAME_M:-x86_64}"
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

cat > "$fakebin/ldd" <<'EOF'
#!/usr/bin/env bash
case "${1##*/}" in
    sketerm-mux)
        printf 'libalpha.so => /lib/libalpha.so (0x0)\n'
        printf 'libbeta.so => /lib/libbeta.so (0x0)\n'
        printf 'libgamma.so => /lib/libgamma.so (0x0)\n'
        printf 'libdelta.so => /lib/libdelta.so (0x0)\n'
        printf 'libepsilon.so => /lib/libepsilon.so (0x0)\n' ;;
    sketerm)
        printf 'libgamma.so => /lib/libgamma.so (0x0)\n'
        printf 'libdelta.so => /lib/libdelta.so (0x0)\n' ;;
    sketerm-webengine)
        printf 'libepsilon.so => /lib/libepsilon.so (0x0)\n'
        printf 'libalpha.so => /lib/libalpha.so (0x0)\n' ;;
esac
EOF

cat > "$fakebin/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --root-owner-group ] && [ "$2" = --build ] || exit 92
stagedir=$3
debfile=$4
[ -x "$stagedir/usr/bin/sketerm-mux" ] || exit 94
if [ -x "$stagedir/usr/bin/sketerm" ]; then
    [ -x "$stagedir/usr/bin/sketerm-webengine" ] || exit 96
    [ -f "$stagedir/usr/share/xdg-desktop-portal/portals/sketerm.portal" ] || exit 97
    [ "$(grep '^Exec=' "$stagedir/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service")" = \
        'Exec=/usr/bin/sketerm portal' ] || exit 98
fi
cp "$stagedir/DEBIAN/control" "$INSTALL_TEST_CONTROL_LOG"
printf '%s\n' "$debfile" > "$INSTALL_TEST_DEB_LOG"
if [ -n "${INSTALL_TEST_STAGED_PORTABLE_LOG:-}" ]; then
    cp "$stagedir/usr/lib/sketerm/sketerm-mux-portable" \
        "$INSTALL_TEST_STAGED_PORTABLE_LOG"
fi
if [ -n "${INSTALL_TEST_REAL_DPKG_DEB:-}" ]; then
    exec "$INSTALL_TEST_REAL_DPKG_DEB" "$@"
fi
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

cat > "$fakebin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '<apt>' >> "$INSTALL_TEST_APT_LOG"
printf ' <%s>' "$@" >> "$INSTALL_TEST_APT_LOG"
printf '\n' >> "$INSTALL_TEST_APT_LOG"
if [ "${1:-}" = install ]; then
    : > "$INSTALL_TEST_DEPS_READY"
fi
EOF

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
    "$fakebin/dpkg" "$fakebin/uname" "$fakebin/ldd" "$fakebin/dpkg-deb" \
    "$fakebin/sudo" "$fakebin/apt-get"

cef_include="$work/cef/include-root"
cef_lib="$work/cef/lib"
mkdir -p "$cef_include/include/capi" "$cef_lib"
: > "$cef_include/include/capi/cef_app_capi.h"
: > "$cef_lib/libcef.so"

set +e
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
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
INSTALL_TEST_APT_LOG="$work/apt.log"
INSTALL_TEST_DEPS_READY="$work/deps-ready"
INSTALL_TEST_CONTROL_LOG="$work/control"

rm -f "$work/unsupported-package-zig.log"
set +e
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_DPKG_ARCH=riscv64 \
    INSTALL_TEST_ZIG_LOG="$work/unsupported-package-zig.log" \
    "$fixture/dist/install.sh" --mux-only --no-install \
    > "$work/unsupported-package-arch.out" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "installer accepted an unsupported package architecture"
[ ! -e "$work/unsupported-package-zig.log" ] \
    || fail "installer started building an unsupported package architecture"
[[ "$(<"$work/unsupported-package-arch.out")" == *"unsupported Linux package architecture"* ]] \
    || fail "installer did not explain its unsupported architecture policy"

rm -f "$INSTALL_TEST_DEPS_READY"
: > "$INSTALL_TEST_APT_LOG"
: > "$work/pkg-config.log"
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    INSTALL_TEST_PKG_CONFIG_FAIL=1 \
    INSTALL_TEST_PKG_CONFIG_LOG="$work/pkg-config.log" \
    INSTALL_TEST_ZIG_PROBE_FRIBIDI=1 \
    INSTALL_TEST_DEPS_MISSING=1 \
    INSTALL_TEST_DEPS_READY="$INSTALL_TEST_DEPS_READY" \
    INSTALL_TEST_APT_LOG="$INSTALL_TEST_APT_LOG" \
    INSTALL_TEST_ALLOW_SUDO=1 \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    INSTALL_TEST_DEB_LOG="$INSTALL_TEST_DEB_LOG" \
    INSTALL_TEST_CONTROL_LOG="$INSTALL_TEST_CONTROL_LOG" \
    INSTALL_TEST_REAL_DPKG_DEB="$real_dpkg_deb" \
    INSTALL_TEST_FORBIDDEN="$INSTALL_TEST_FORBIDDEN" \
    "$fixture/dist/install.sh" --mux-only --deps --no-install \
    > "$work/debian-mux-deps.out" 2>&1
printf '%s\n' \
    '<apt> <update>' \
    '<apt> <install> <-y> <build-essential> <pkg-config> <ncurses-bin> <libfribidi-dev>' \
    > "$work/expected-mux-apt.log"
cmp -s "$work/expected-mux-apt.log" "$INSTALL_TEST_APT_LOG" \
    || fail "--mux-only --deps package list or apt order did not match"
printf '%s\n' \
    '<pkg-config> <--cflags-only-I> <fribidi>' \
    '<pkg-config> <--cflags-only-I> <fribidi>' \
    > "$work/expected-mux-pkg-config.log"
cmp -s "$work/expected-mux-pkg-config.log" "$work/pkg-config.log" \
    || fail "mux builds did not probe fribidi cleanly after dependency installation"

BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    CEF_INCLUDE="$cef_include" \
    CEF_LIB="$cef_lib" \
    INSTALL_TEST_PKG_CONFIG_FAIL=1 \
    INSTALL_TEST_DEPS_MISSING=1 \
    INSTALL_TEST_DEPS_READY="$INSTALL_TEST_DEPS_READY" \
    INSTALL_TEST_APT_LOG="$INSTALL_TEST_APT_LOG" \
    INSTALL_TEST_ALLOW_SUDO=1 \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    INSTALL_TEST_DEB_LOG="$INSTALL_TEST_DEB_LOG" \
    INSTALL_TEST_CONTROL_LOG="$INSTALL_TEST_CONTROL_LOG" \
    INSTALL_TEST_REAL_DPKG_DEB="$real_dpkg_deb" \
    INSTALL_TEST_FORBIDDEN="$INSTALL_TEST_FORBIDDEN" \
    "$fixture/dist/install.sh" --gui-only --deps --no-install \
    > "$work/debian.out" 2>&1

[ -f "$(<"$INSTALL_TEST_DEB_LOG")" ] \
    || fail "non-Arch --no-install did not build a package"
[ ! -e "$INSTALL_TEST_FORBIDDEN" ] \
    || fail "non-Arch --no-install attempted a privileged install"
[[ "$(<"$INSTALL_TEST_ZIG_LOG")" == *"<call> <build> <-Doptimize=ReleaseFast>"* ]] \
    || fail "non-Arch GUI build was not invoked"
[[ "$(<"$INSTALL_TEST_ZIG_LOG")" == *"<call> <build> <mux-portable> <-Doptimize=ReleaseFast> <-Dportable-target=x86_64-linux-musl>"* ]] \
    || fail "non-Arch portable daemon build was not invoked"
[[ "$(<"$INSTALL_TEST_ZIG_LOG")" == *"<call> <build> <web> <-Doptimize=ReleaseFast> <-Dcef-include=$cef_include> <-Dcef-lib=$cef_lib>"* ]] \
    || fail "non-Arch browser helper build was not invoked"
[[ "$(<"$INSTALL_TEST_APT_LOG")" == *"<apt> <install> <-y> <build-essential> <pkg-config>"* ]] \
    || fail "--gui-only --deps did not install GUI dependencies before probing"
[[ "$(<"$work/debian.out")" == *"staged only, not installed"* ]] \
    || fail "non-Arch --no-install result was not reported"
expected_depends='Depends: alpha-runtime, beta-runtime, delta-runtime, epsilon-runtime, gamma-runtime'
[ "$(grep '^Depends:' "$INSTALL_TEST_CONTROL_LOG")" = "$expected_depends" ] \
    || fail "Debian Depends line was not comma-space separated"
if [ -n "$real_dpkg_deb" ]; then
    "$real_dpkg_deb" --info "$(<"$INSTALL_TEST_DEB_LOG")" > "$work/deb-info"
    [[ "$(<"$work/deb-info")" == *"$expected_depends"* ]] \
        || fail "dpkg-deb --info did not parse the expected Depends line"
fi

rm -f "$INSTALL_TEST_DEPS_READY"
: > "$INSTALL_TEST_ZIG_LOG"
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    CEF_INCLUDE="$cef_include" \
    CEF_LIB="$cef_lib" \
    INSTALL_TEST_PKG_CONFIG_FAIL=1 \
    INSTALL_TEST_DEPS_MISSING=1 \
    INSTALL_TEST_DEPS_READY="$INSTALL_TEST_DEPS_READY" \
    INSTALL_TEST_APT_LOG="$INSTALL_TEST_APT_LOG" \
    INSTALL_TEST_ALLOW_SUDO=1 \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    INSTALL_TEST_DEB_LOG="$INSTALL_TEST_DEB_LOG" \
    INSTALL_TEST_CONTROL_LOG="$INSTALL_TEST_CONTROL_LOG" \
    INSTALL_TEST_REAL_DPKG_DEB="$real_dpkg_deb" \
    INSTALL_TEST_FORBIDDEN="$INSTALL_TEST_FORBIDDEN" \
    "$fixture/dist/install.sh" --deps --no-install \
    > "$work/debian-auto.out" 2>&1
[[ "$(<"$INSTALL_TEST_ZIG_LOG")" == *"<call> <build> <-Doptimize=ReleaseFast>"* ]] \
    || fail "auto --deps stayed locked to a mux-only build"

rm -f "$INSTALL_TEST_DEPS_READY" "$INSTALL_TEST_ZIG_LOG"
: > "$INSTALL_TEST_APT_LOG"
set +e
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    INSTALL_TEST_PKG_CONFIG_FAIL=1 \
    INSTALL_TEST_DEPS_READY="$INSTALL_TEST_DEPS_READY" \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    "$fixture/dist/install.sh" --gui-only --no-install \
    > "$work/debian-no-deps.out" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "--gui-only without --deps ignored missing GUI dependencies"
[ ! -e "$INSTALL_TEST_ZIG_LOG" ] || fail "--gui-only probed dependencies after starting the build"
[ ! -s "$INSTALL_TEST_APT_LOG" ] || fail "GUI dependencies were installed without --deps"

: > "$INSTALL_TEST_ZIG_LOG"
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_PKG_CONFIG_FAIL=1 \
    INSTALL_TEST_DEPS_READY="$INSTALL_TEST_DEPS_READY" \
    SKETERM_TIC="$fakebin/tic" \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    INSTALL_TEST_DEB_LOG="$INSTALL_TEST_DEB_LOG" \
    INSTALL_TEST_CONTROL_LOG="$INSTALL_TEST_CONTROL_LOG" \
    INSTALL_TEST_REAL_DPKG_DEB="$real_dpkg_deb" \
    INSTALL_TEST_FORBIDDEN="$INSTALL_TEST_FORBIDDEN" \
    "$fixture/dist/install.sh" --no-install \
    > "$work/debian-auto-no-deps.out" 2>&1
[[ "$(<"$INSTALL_TEST_ZIG_LOG")" == *"<call> <build> <mux> <-Doptimize=ReleaseFast>"* ]] \
    || fail "auto mode without --deps did not degrade to mux"
[[ "$(<"$work/debian-auto-no-deps.out")" == *"building the sketerm-mux daemon only"* ]] \
    || fail "auto mode without --deps did not explain its mux fallback"

for bad_zig in 0.15.2 0.17.0; do
    rm -f "$INSTALL_TEST_ZIG_LOG"
    set +e
    BASH_ENV="$work/no-packager.bash" \
        PATH="$fakebin:$PATH" \
        SKETERM_TIC="$fakebin/tic" \
        INSTALL_TEST_ZIG_VERSION="$bad_zig" \
        INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
        "$fixture/dist/install.sh" --mux-only --no-install \
        > "$work/bad-zig.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail "unsupported Zig $bad_zig was accepted"
    [[ "$(<"$work/bad-zig.out")" == *"requires Zig 0.16.x"* ]] \
        || fail "unsupported Zig $bad_zig did not produce clear guidance"
    [ ! -e "$INSTALL_TEST_ZIG_LOG" ] || fail "unsupported Zig $bad_zig started a build"
done

rm -f "$INSTALL_TEST_ZIG_LOG"
unsafe_prefix="$work/plain-prefix"$'\n''Exec=/bin/false'
set +e
BASH_ENV="$work/no-packager.bash" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    "$fixture/dist/install.sh" --gui-only --no-install \
        --prefix "$unsafe_prefix" \
    > "$work/plain-unsafe-prefix.out" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "plain install accepted a newline in its prefix"
[[ "$(<"$work/plain-unsafe-prefix.out")" == \
    *"absolute path free of newlines and control characters"* ]] \
    || fail "unsafe plain prefix failure was not explicit"
[ ! -e "$INSTALL_TEST_ZIG_LOG" ] \
    || fail "unsafe plain prefix was rejected only after starting the build"

: > "$INSTALL_TEST_APT_LOG"
set +e
BASH_ENV="$work/no-makepkg.bash" \
    PATH="$fakebin:$PATH" \
    INSTALL_TEST_ZIG_VERSION=0.15.2 \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    INSTALL_TEST_APT_LOG="$INSTALL_TEST_APT_LOG" \
    "$fixture/dist/install.sh" --mux-only --deps --no-install \
    > "$work/debian-bad-zig.out" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "dpkg --deps accepted Zig 0.15.2"
[ ! -s "$INSTALL_TEST_APT_LOG" ] || fail "dpkg --deps ran apt before rejecting Zig"

mkdir -p "$work/plain-tmp" "$work/plain-prefix"
BASH_ENV="$work/no-packager.bash" \
    TMPDIR="$work/plain-tmp" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    CEF_INCLUDE="$cef_include" \
    CEF_LIB="$cef_lib" \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    "$fixture/dist/install.sh" --gui-only --no-install \
    > "$work/plain.out" 2>&1
[[ "$(<"$work/plain.out")" == *"staged in $work/plain-tmp/"* ]] \
    || fail "plain --no-install did not preserve and report its staging tree"
plain_stage=("$work/plain-tmp"/tmp.*)
[ ${#plain_stage[@]} -eq 1 ] || fail "plain staging tree was not preserved exactly once"
for identity in dev.sker.sketerm dev.sker.sketerm.files dev.sker.sketerm.viewer \
                dev.sker.sketerm.editor dev.sker.sketerm.web; do
    [ -e "${plain_stage[0]}/usr/share/applications/$identity.desktop" ] \
        || fail "plain GUI stage omitted $identity.desktop"
    [ -e "${plain_stage[0]}/usr/share/icons/hicolor/scalable/apps/$identity.svg" ] \
        || fail "plain GUI stage omitted $identity.svg"
done
for path in \
    usr/bin/sketerm-files usr/bin/sketerm-viewer usr/bin/sketerm-editor \
    usr/bin/sketerm-web usr/bin/sketerm-webengine \
    usr/share/icons/hicolor/scalable/actions/sketerm-reader-symbolic.svg \
    usr/share/xdg-desktop-portal/portals/sketerm.portal \
    usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service; do
    [ -e "${plain_stage[0]}/$path" ] || fail "plain GUI stage omitted $path"
done
plain_default_service="${plain_stage[0]}/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service"
[ "$(grep '^Exec=' "$plain_default_service")" = \
    'Exec="/usr/local/bin/sketerm" portal' ] \
    || fail "default plain stage did not activate /usr/local/bin/sketerm"

mkdir -p "$work/plain-no-cef-tmp"
set +e
BASH_ENV="$work/no-packager.bash" \
    TMPDIR="$work/plain-no-cef-tmp" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    CEF_INCLUDE="$work/no-cef-include" \
    CEF_LIB="$work/no-cef-lib" \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    "$fixture/dist/install.sh" --gui-only --no-install \
    > "$work/plain-no-cef.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || fail "CEF-less plain stage failed: $(<"$work/plain-no-cef.out")"
plain_no_cef_stage=("$work/plain-no-cef-tmp"/tmp.*)
[ -e "${plain_no_cef_stage[0]}/usr/bin/sketerm-web" ] \
    || fail "CEF-less stage omitted browser identity"
[ ! -e "${plain_no_cef_stage[0]}/usr/bin/sketerm-webengine" ] \
    || fail "CEF-less stage packaged an unbuilt browser helper"
[[ "$(<"$work/plain-no-cef.out")" == *"packaging browser identity without sketerm-webengine"* ]] \
    || fail "CEF-less stage did not report its browser-helper limitation"

cat > "$fakebin/cp" <<'EOF'
#!/usr/bin/env bash
dest=${!#}
if [ -n "${INSTALL_TEST_CP_FAIL_DEST:-}" ] \
        && [ "$dest" = "$INSTALL_TEST_CP_FAIL_DEST" ]; then
    printf 'simulated interrupted plain install\n' >&2
    exit 73
fi
exec /usr/bin/cp "$@"
EOF
chmod +x "$fakebin/cp"

run_plain_gui_install() {
    local output=$1 install_prefix=$2 with_cef=$3
    local include lib
    if [ "$with_cef" -eq 1 ]; then
        include=$cef_include
        lib=$cef_lib
    else
        include=$work/no-cef-include
        lib=$work/no-cef-lib
    fi
    BASH_ENV="$work/no-packager.bash" \
        PATH="$fakebin:$PATH" \
        SKETERM_TIC="$fakebin/tic" \
        CEF_INCLUDE="$include" \
        CEF_LIB="$lib" \
        INSTALL_TEST_ALLOW_SUDO=1 \
        INSTALL_TEST_CP_FAIL_DEST="${INSTALL_TEST_CP_FAIL_DEST:-}" \
        INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
        "$fixture/dist/install.sh" --gui-only --prefix "$install_prefix" \
        > "$output" 2>&1
}

# Prefixes that need both service-file escaping and D-Bus argv quoting retain
# their exact executable path, non-ASCII bytes included: a home directory with
# an accented name must install like any other. If the D-Bus test tools are
# installed, exercise the actual activation parser as well as the staged text.
# UTF-8 e-acute / i-diaeresis, spelled in escapes so this file stays ASCII.
plain_accent=$'pr\303\251fix na\303\257ve'
plain_special_prefix="$work/plain $plain_accent \$cash \`tick\` 'single' \"double\" back\\slash #hash &semi; =eq"
mkdir -p "$plain_special_prefix"
run_plain_gui_install "$work/plain-special.out" "$plain_special_prefix" 1
plain_special_service="$plain_special_prefix/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service"
plain_special_manifest="$plain_special_prefix/share/sketerm/plain-install-manifest"
[ -x "$plain_special_prefix/bin/sketerm" ] \
    || fail "custom-prefix activation command does not exist"
[ "$(grep -c '^Exec=' "$plain_special_service")" -eq 1 ] \
    || fail "custom-prefix service does not contain exactly one Exec entry"
grep -Fqx 'Name=org.freedesktop.impl.portal.desktop.sketerm' \
    "$plain_special_service" \
    || fail "custom-prefix service changed its D-Bus name"
grep -Fq "$plain_accent" "$plain_special_service" \
    || fail "custom-prefix service lost the non-ASCII part of the prefix"
grep -Fqx 'share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service' \
    "$plain_special_manifest" \
    || fail "plain manifest omitted the generated portal service"

if command -v dbus-run-session >/dev/null 2>&1 \
        && command -v dbus-send >/dev/null 2>&1 \
        && command -v dbus-test-tool >/dev/null 2>&1 \
        && command -v timeout >/dev/null 2>&1; then
    rm -f "$plain_special_prefix/bin/sketerm"
    cat > "$plain_special_prefix/bin/sketerm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$INSTALL_TEST_ACTIVATION_LOG"
exec dbus-test-tool echo --name=org.freedesktop.impl.portal.desktop.sketerm
EOF
    chmod +x "$plain_special_prefix/bin/sketerm"
    INSTALL_TEST_ACTIVATION_LOG="$work/activation-argv" \
        XDG_DATA_HOME="$work/activation-data-home" \
        XDG_DATA_DIRS="$plain_special_prefix/share" \
        dbus-run-session -- timeout 15 dbus-send --session --print-reply \
            --dest=org.freedesktop.impl.portal.desktop.sketerm \
            /org/freedesktop/portal/desktop org.freedesktop.DBus.Peer.Ping \
            > "$work/activation.out" 2>&1 \
        || fail "D-Bus could not activate the custom-prefix service: $(<"$work/activation.out")"
    [ "$(<"$work/activation-argv")" = portal ] \
        || fail "D-Bus activation did not execute the generated command"
fi

# Plain installs own only paths listed in their prefix manifest. A CEF-less
# upgrade removes a previously managed helper even when it was modified, but
# leaves unrelated files alone. Re-enabling CEF installs and tracks it again.
plain_upgrade_prefix="$work/plain-upgrade-prefix"
mkdir -p "$plain_upgrade_prefix"
run_plain_gui_install "$work/plain-upgrade-cef.out" "$plain_upgrade_prefix" 1
plain_manifest="$plain_upgrade_prefix/share/sketerm/plain-install-manifest"
[ -x "$plain_upgrade_prefix/bin/sketerm-webengine" ] \
    || fail "CEF plain install omitted sketerm-webengine"
[ -f "$plain_manifest" ] \
    || fail "plain install did not publish its managed-file manifest"
grep -Fqx bin/sketerm-webengine "$plain_manifest" \
    || fail "plain manifest omitted sketerm-webengine"
grep -Fqx 'share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service' \
    "$plain_manifest" \
    || fail "plain upgrade manifest omitted the portal service"

mkdir -p "$plain_upgrade_prefix/share/unrelated"
printf 'keep bin\n' > "$plain_upgrade_prefix/bin/not-sketerm"
printf 'keep shared\n' > "$plain_upgrade_prefix/share/unrelated/keep"
printf 'keep local\n' > "$plain_upgrade_prefix/share/sketerm/local-note"
printf 'retired asset\n' > "$plain_upgrade_prefix/share/sketerm/retired-asset"
printf 'share/sketerm/retired-asset\n' >> "$plain_manifest"
printf 'locally modified helper\n' > "$plain_upgrade_prefix/bin/sketerm-webengine"
chmod +x "$plain_upgrade_prefix/bin/sketerm-webengine"
printf '%s\n' \
    '[D-BUS Service]' \
    'Name=org.freedesktop.impl.portal.desktop.sketerm' \
    'Exec=/stale/sketerm portal' \
    > "$plain_upgrade_prefix/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service"

run_plain_gui_install "$work/plain-upgrade-no-cef.out" "$plain_upgrade_prefix" 0
[ ! -e "$plain_upgrade_prefix/bin/sketerm-webengine" ] \
    || fail "CEF-less upgrade retained a modified managed helper"
! grep -Fqx bin/sketerm-webengine "$plain_manifest" \
    || fail "CEF-less upgrade kept sketerm-webengine in the manifest"
[ "$(<"$plain_upgrade_prefix/bin/not-sketerm")" = 'keep bin' ] \
    || fail "plain upgrade changed an unrelated bin file"
[ "$(<"$plain_upgrade_prefix/share/unrelated/keep")" = 'keep shared' ] \
    || fail "plain upgrade changed an unrelated share file"
[ "$(<"$plain_upgrade_prefix/share/sketerm/local-note")" = 'keep local' ] \
    || fail "plain upgrade changed an untracked file in a managed directory"
[ ! -e "$plain_upgrade_prefix/share/sketerm/retired-asset" ] \
    || fail "plain upgrade retained another obsolete managed asset"
[ "$(grep '^Exec=' "$plain_upgrade_prefix/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service")" = \
    "Exec=\"$plain_upgrade_prefix/bin/sketerm\" portal" ] \
    || fail "plain upgrade did not refresh the portal activation command"

run_plain_gui_install "$work/plain-upgrade-reenable.out" "$plain_upgrade_prefix" 1
cmp -s "$fixture/zig-out/bin/sketerm-webengine" \
    "$plain_upgrade_prefix/bin/sketerm-webengine" \
    || fail "re-enabled CEF did not restore the current helper"
grep -Fqx bin/sketerm-webengine "$plain_manifest" \
    || fail "re-enabled CEF did not restore helper ownership"

# Obsolete cleanup happens before the overlay, while manifest replacement is
# last. An interrupted copy therefore cannot leave the stale helper runnable,
# and the old manifest remains available for the next retry.
cp "$plain_manifest" "$work/plain-manifest-before-interrupt"
set +e
INSTALL_TEST_CP_FAIL_DEST="$plain_upgrade_prefix/" \
    run_plain_gui_install "$work/plain-upgrade-interrupted.out" \
        "$plain_upgrade_prefix" 0
status=$?
set -e
[ "$status" -eq 1 ] || fail "interrupted plain copy reported success"
[[ "$(<"$work/plain-upgrade-interrupted.out")" == *"could not copy the staged install"* ]] \
    || fail "interrupted plain copy was not reported"
! grep -q ' done$' "$work/plain-upgrade-interrupted.out" \
    || fail "interrupted plain copy printed the final success report"
[ ! -e "$plain_upgrade_prefix/bin/sketerm-webengine" ] \
    || fail "interrupted CEF-less upgrade left the stale helper runnable"
cmp -s "$work/plain-manifest-before-interrupt" "$plain_manifest" \
    || fail "interrupted plain copy published a replacement manifest"

run_plain_gui_install "$work/plain-upgrade-retry.out" "$plain_upgrade_prefix" 0
! grep -Fqx bin/sketerm-webengine "$plain_manifest" \
    || fail "plain retry did not retire helper ownership"
run_plain_gui_install "$work/plain-upgrade-reenable-again.out" "$plain_upgrade_prefix" 1
[ -x "$plain_upgrade_prefix/bin/sketerm-webengine" ] \
    || fail "CEF re-enable after an interrupted upgrade omitted the helper"

# The first fixed upgrade has no previous manifest to consult. The exact
# historical optional-helper path is migrated explicitly; no other untracked
# prefix content is inferred to be owned.
plain_legacy_prefix="$work/plain-legacy-prefix"
mkdir -p "$plain_legacy_prefix/bin" "$plain_legacy_prefix/share/legacy"
cp "$fixture/zig-out/bin/sketerm-webengine" \
    "$plain_legacy_prefix/bin/sketerm-webengine"
printf 'legacy unrelated\n' > "$plain_legacy_prefix/share/legacy/keep"
run_plain_gui_install "$work/plain-legacy-upgrade.out" "$plain_legacy_prefix" 0
[ ! -e "$plain_legacy_prefix/bin/sketerm-webengine" ] \
    || fail "first manifest upgrade retained the legacy helper"
[ "$(<"$plain_legacy_prefix/share/legacy/keep")" = 'legacy unrelated' ] \
    || fail "first manifest upgrade changed unrelated legacy content"

# A managed path that cannot be removed is a hard failure before new files or
# a new ownership manifest are published.
plain_blocked_prefix="$work/plain-blocked-prefix"
mkdir -p "$plain_blocked_prefix"
run_plain_gui_install "$work/plain-blocked-setup.out" "$plain_blocked_prefix" 1
blocked_manifest="$plain_blocked_prefix/share/sketerm/plain-install-manifest"
cp "$blocked_manifest" "$work/plain-blocked-manifest-before"
rm -f "$plain_blocked_prefix/bin/sketerm-webengine"
mkdir "$plain_blocked_prefix/bin/sketerm-webengine"
set +e
run_plain_gui_install "$work/plain-blocked-upgrade.out" "$plain_blocked_prefix" 0
status=$?
set -e
[ "$status" -eq 1 ] || fail "failed obsolete cleanup reported success"
[[ "$(<"$work/plain-blocked-upgrade.out")" == *"could not remove obsolete managed file"* ]] \
    || fail "failed obsolete cleanup was not reported"
! grep -q ' done$' "$work/plain-blocked-upgrade.out" \
    || fail "failed obsolete cleanup printed the final success report"
cmp -s "$work/plain-blocked-manifest-before" "$blocked_manifest" \
    || fail "failed obsolete cleanup published a replacement manifest"

BASH_ENV="$work/no-packager.bash" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    INSTALL_TEST_ALLOW_SUDO=1 \
    INSTALL_TEST_ZIG_LOG="$INSTALL_TEST_ZIG_LOG" \
    "$fixture/dist/install.sh" --mux-only --prefix "$work/plain-prefix" \
    > "$work/plain-prefix.out" 2>&1
[ -x "$work/plain-prefix/bin/sketerm-mux" ] \
    || fail "plain --prefix did not receive the installed daemon"

(
    export INSTALL_TEST_ZIG_LOG="$work/package-zig.log"
    CARCH=x86_64
    startdir="$fixture/dist"
    pkgdir="$work/pkg"
    source "$here/PKGBUILD"
    [[ " ${depends[*]} " == *" gtk4>=4.14 "* ]] || fail "PKGBUILD lacks GTK minimum"
    [[ " ${depends[*]} " == *" libadwaita>=1.4 "* ]] || fail "PKGBUILD lacks libadwaita minimum"
    [[ " ${depends[*]} " == *" glib2>=2.74 "* ]] || fail "PKGBUILD lacks GLib minimum"
    [[ " ${makedepends[*]} " == *" zig>=0.16.0 "* ]] || fail "PKGBUILD lacks Zig minimum"
    [[ " ${makedepends[*]} " == *" zig<0.17.0 "* ]] || fail "PKGBUILD lacks Zig upper bound"
    PATH="$fakebin:$PATH" build
    PATH="$fakebin:$PATH" package
)

[[ "$(<"$work/package-zig.log")" == *"<call> <build> <web> <-Doptimize=ReleaseFast> <-Dcef-include=/usr/include/cef> <-Dcef-lib=/usr/lib/cef>"* ]] \
    || fail "PKGBUILD build() did not build sketerm-webengine"

[ -x "$work/pkg/usr/bin/sketerm-webengine" ] \
    || fail "PKGBUILD package() did not include sketerm-webengine"
[ "$(grep '^Exec=' "$work/pkg/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service")" = \
    'Exec=/usr/bin/sketerm portal' ] \
    || fail "PKGBUILD package() did not retain the canonical /usr activation path"
cmp -s "$root/data/org.freedesktop.impl.portal.desktop.sketerm.service" \
    "$work/pkg/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service" \
    || fail "PKGBUILD package() rewrote the canonical portal service"
[ ! -e "$work/pkg/usr/share/sketerm/plain-install-manifest" ] \
    || fail "PKGBUILD package() included plain-install ownership metadata"
cmp -s "$fixture/zig-out/bin/sketerm-webengine" \
    "$work/pkg/usr/bin/sketerm-webengine" \
    || fail "packaged sketerm-webengine did not come from the current build"

# ------------------------------------------------------------------------
# The version algorithm and the build recipe exist ONCE, in stage.sh, and
# both backends reach them through it. These assertions are what stops the
# copies growing back: they compare each caller's observable result against
# a direct call to the shared helper.

source "$here/stage.sh"

[ "$(sketerm_portable_target_for_arch x86_64)" = x86_64-linux-musl ] \
    || fail "x86_64 portable target mapping is wrong"
[ "$(sketerm_portable_target_for_arch amd64)" = x86_64-linux-musl ] \
    || fail "amd64 portable target mapping is wrong"
[ "$(sketerm_portable_target_for_arch aarch64)" = aarch64-linux-musl ] \
    || fail "aarch64 portable target mapping is wrong"
[ "$(sketerm_portable_target_for_arch arm64)" = aarch64-linux-musl ] \
    || fail "arm64 portable target mapping is wrong"
set +e
sketerm_portable_target_for_arch riscv64 > "$work/unsupported-arch.out" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "unsupported packaging architecture was accepted"
[[ "$(<"$work/unsupported-arch.out")" == *"unsupported Linux package architecture"* ]] \
    || fail "unsupported packaging architecture failure was not explicit"

shared_ver=$(sketerm_pkgver "$fixture")
[ -n "$shared_ver" ] || fail "sketerm_pkgver produced no version"
[ "$shared_ver" = "$(grep -m1 '\.version' "$root/build.zig.zon" \
    | sed -E 's/.*"([^"]+)".*/\1/')" ] \
    || fail "sketerm_pkgver did not derive the version from build.zig.zon"

# The Debian backend's package filename must carry exactly that version.
# (The last deb built above is the auto-mode mux one; only the version part
# is asserted here, the name part is covered by the runs that produced it.)
[[ "$(basename "$(<"$INSTALL_TEST_DEB_LOG")")" == *"_${shared_ver}-1_amd64.deb" ]] \
    || fail "dpkg backend version diverged from sketerm_pkgver"

# ...and so must PKGBUILD's pkgver().
arch_ver=$(
    startdir="$fixture/dist"
    source "$here/PKGBUILD"
    pkgver
)
[ "$arch_ver" = "$shared_ver" ] \
    || fail "PKGBUILD pkgver() diverged from sketerm_pkgver ($arch_ver vs $shared_ver)"

# PKGBUILD build() must be nothing but the shared recipe with the distro
# CEF paths: same zig invocations, same order.
(
    export PATH="$fakebin:$PATH" INSTALL_TEST_ZIG_LOG="$work/shared-arch-build.log"
    : > "$INSTALL_TEST_ZIG_LOG"
    sketerm_build "$fixture" gui 1 /usr/include/cef /usr/lib/cef "" x86_64 >/dev/null 2>&1
)
cmp -s "$work/shared-arch-build.log" "$work/package-zig.log" \
    || fail "PKGBUILD build() diverged from the shared sketerm_build recipe"

# The non-Arch GUI build must be the same recipe with the probed CEF paths.
mkdir -p "$work/shared-tmp"
BASH_ENV="$work/no-packager.bash" \
    TMPDIR="$work/shared-tmp" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    CEF_INCLUDE="$cef_include" \
    CEF_LIB="$cef_lib" \
    INSTALL_TEST_ZIG_LOG="$work/installer-gui-build.log" \
    "$fixture/dist/install.sh" --gui-only --no-install \
    > "$work/installer-gui-build.out" 2>&1
(
    export PATH="$fakebin:$PATH" INSTALL_TEST_ZIG_LOG="$work/shared-gui-build.log"
    : > "$INSTALL_TEST_ZIG_LOG"
    sketerm_build "$fixture" gui 1 "$cef_include" "$cef_lib" "" amd64 >/dev/null 2>&1
)
cmp -s "$work/shared-gui-build.log" "$work/installer-gui-build.log" \
    || fail "install.sh GUI build diverged from the shared sketerm_build recipe"

# Same for the mux-only kind, and for a GUI build with no CEF available.
BASH_ENV="$work/no-packager.bash" \
    TMPDIR="$work/shared-tmp" \
    PATH="$fakebin:$PATH" \
    SKETERM_TIC="$fakebin/tic" \
    INSTALL_TEST_ZIG_LOG="$work/installer-mux-build.log" \
    "$fixture/dist/install.sh" --mux-only --no-install \
    > "$work/installer-mux-build.out" 2>&1
(
    export PATH="$fakebin:$PATH" INSTALL_TEST_ZIG_LOG="$work/shared-mux-build.log"
    : > "$INSTALL_TEST_ZIG_LOG"
    sketerm_build "$fixture" mux 0 "$cef_include" "$cef_lib" "no cef" amd64 >/dev/null 2>&1
)
cmp -s "$work/shared-mux-build.log" "$work/installer-mux-build.log" \
    || fail "install.sh mux build diverged from the shared sketerm_build recipe"
[[ "$(<"$work/shared-mux-build.log")" != *"<web>"* ]] \
    || fail "shared mux recipe built the browser helper"

(
    export PATH="$fakebin:$PATH" INSTALL_TEST_ZIG_LOG="$work/shared-nocef-build.log"
    : > "$INSTALL_TEST_ZIG_LOG"
    sketerm_build "$fixture" gui 0 /nope /nope "CEF headers or runtime not found" x86_64 \
        > "$work/shared-nocef.out" 2>&1
)
[[ "$(<"$work/shared-nocef-build.log")" != *"<web>"* ]] \
    || fail "shared recipe built the browser helper without CEF"
[[ "$(<"$work/shared-nocef.out")" == *"packaging browser identity without sketerm-webengine"* ]] \
    || fail "shared recipe did not explain the omitted browser helper"

# Build the real deployment artifact for each supported package architecture,
# then pass it through both plain and Debian staging. Reading e_machine from the
# staged/package copy catches a target argument that was omitted or mismapped.
elf_machine() {
    local lo hi
    read -r lo hi < <(od -An -tu1 -j18 -N2 "$1")
    printf '%s\n' "$((lo + hi * 256))"
}

for spec in \
        'x86_64 x86_64-linux-musl 62 amd64' \
        'aarch64 aarch64-linux-musl 183 arm64'; do
    read -r host_arch portable_target machine deb_arch <<< "$spec"
    cross_prefix="$work/cross-$host_arch"
    (
        cd "$root"
        zig build mux-portable -Doptimize=ReleaseFast \
            -Dportable-target="$portable_target" --prefix "$cross_prefix"
    )
    cross_artifact="$cross_prefix/bin/sketerm-mux-portable"
    [ "$(elf_machine "$cross_artifact")" -eq "$machine" ] \
        || fail "$portable_target build has the wrong ELF e_machine"

    cp "$cross_artifact" "$fixture/zig-out/bin/sketerm-mux"
    cp "$cross_artifact" "$fixture/zig-out/bin/sketerm-mux-portable"

    plain_arch_tmp="$work/plain-$host_arch"
    mkdir -p "$plain_arch_tmp"
    : > "$work/plain-$host_arch-zig.log"
    BASH_ENV="$work/no-packager.bash" \
        TMPDIR="$plain_arch_tmp" \
        PATH="$fakebin:$PATH" \
        SKETERM_TIC="$fakebin/tic" \
        INSTALL_TEST_UNAME_M="$host_arch" \
        INSTALL_TEST_ZIG_LOG="$work/plain-$host_arch-zig.log" \
        "$fixture/dist/install.sh" --mux-only --no-install \
        > "$work/plain-$host_arch.out" 2>&1
    plain_arch_stages=("$plain_arch_tmp"/tmp.*)
    [ ${#plain_arch_stages[@]} -eq 1 ] \
        || fail "$host_arch plain packaging did not preserve exactly one stage"
    plain_portable="${plain_arch_stages[0]}/usr/lib/sketerm/sketerm-mux-portable"
    [ "$(elf_machine "$plain_portable")" -eq "$machine" ] \
        || fail "$host_arch plain stage has the wrong portable ELF e_machine"
    [[ "$(<"$work/plain-$host_arch-zig.log")" == \
        *"<call> <build> <mux-portable> <-Doptimize=ReleaseFast> <-Dportable-target=$portable_target>"* ]] \
        || fail "$host_arch plain packaging did not pass $portable_target"

    : > "$work/debian-$host_arch-zig.log"
    staged_portable="$work/debian-$host_arch-portable"
    BASH_ENV="$work/no-makepkg.bash" \
        PATH="$fakebin:$PATH" \
        SKETERM_TIC="$fakebin/tic" \
        INSTALL_TEST_DPKG_ARCH="$deb_arch" \
        INSTALL_TEST_ZIG_LOG="$work/debian-$host_arch-zig.log" \
        INSTALL_TEST_DEB_LOG="$INSTALL_TEST_DEB_LOG" \
        INSTALL_TEST_CONTROL_LOG="$INSTALL_TEST_CONTROL_LOG" \
        INSTALL_TEST_STAGED_PORTABLE_LOG="$staged_portable" \
        INSTALL_TEST_REAL_DPKG_DEB="$real_dpkg_deb" \
        INSTALL_TEST_FORBIDDEN="$INSTALL_TEST_FORBIDDEN" \
        "$fixture/dist/install.sh" --mux-only --no-install \
        > "$work/debian-$host_arch.out" 2>&1
    [ "$(grep '^Architecture:' "$INSTALL_TEST_CONTROL_LOG")" = "Architecture: $deb_arch" ] \
        || fail "$host_arch Debian control architecture is inconsistent"
    [[ "$(basename "$(<"$INSTALL_TEST_DEB_LOG")")" == *"_${deb_arch}.deb" ]] \
        || fail "$host_arch Debian filename architecture is inconsistent"
    [ "$(elf_machine "$staged_portable")" -eq "$machine" ] \
        || fail "$host_arch Debian stage has the wrong portable ELF e_machine"
    [[ "$(<"$work/debian-$host_arch-zig.log")" == \
        *"<call> <build> <mux-portable> <-Doptimize=ReleaseFast> <-Dportable-target=$portable_target>"* ]] \
        || fail "$host_arch Debian packaging did not pass $portable_target"

    if [ -n "$real_dpkg_deb" ]; then
        deb_extract="$work/debian-$host_arch-extract"
        mkdir -p "$deb_extract"
        "$real_dpkg_deb" -x "$(<"$INSTALL_TEST_DEB_LOG")" "$deb_extract"
        [ "$($real_dpkg_deb -f "$(<"$INSTALL_TEST_DEB_LOG")" Architecture)" = "$deb_arch" ] \
            || fail "$host_arch Debian archive architecture is inconsistent"
        [ "$(elf_machine "$deb_extract/usr/lib/sketerm/sketerm-mux-portable")" -eq "$machine" ] \
            || fail "$host_arch Debian archive has the wrong portable ELF e_machine"
    fi
done

printf 'PASS: installer argument routing and package contents\n'
