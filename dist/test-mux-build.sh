#!/usr/bin/env bash

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

real_pkg_config=$(command -v pkg-config)
mkdir -p "$work/bin"
cat > "$work/bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SKETERM_PKG_CONFIG_LOG"
for arg in "$@"; do
    case "$arg" in
        gtk4|libadwaita-1|glib-2.0|gio-2.0|gio-unix-2.0|freetype2|harfbuzz|epoxy|fontconfig|vpx|libpulse|libpulse-mainloop-glib)
            printf 'forbidden GUI pkg-config probe: %s\n' "$arg" >&2
            exit 86 ;;
    esac
done
exec "$SKETERM_REAL_PKG_CONFIG" "$@"
EOF
chmod +x "$work/bin/pkg-config"

run_mux_build() {
    local step=$1
    PATH="$work/bin:$PATH" \
        PKG_CONFIG="$work/bin/pkg-config" \
        SKETERM_REAL_PKG_CONFIG="$real_pkg_config" \
        SKETERM_PKG_CONFIG_LOG="$work/pkg-config.log" \
        zig build "$step" -Doptimize=ReleaseFast \
            --cache-dir "$work/cache-$step"
}

cd "$root"
run_mux_build mux
run_mux_build mux-portable

if grep -Eq 'gtk4|libadwaita|glib-2.0|gio|freetype|harfbuzz|epoxy|fontconfig|vpx|libpulse' \
        "$work/pkg-config.log"; then
    printf 'FAIL: mux build probed GUI dependencies\n' >&2
    exit 1
fi
if ! grep -q 'fribidi' "$work/pkg-config.log"; then
    printf 'FAIL: clean mux builds did not probe fribidi build headers\n' >&2
    exit 1
fi

printf 'PASS: mux builds avoid GUI dependency probes\n'
