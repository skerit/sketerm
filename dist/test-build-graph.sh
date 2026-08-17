#!/usr/bin/env bash

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

list_bins() {
    local prefix=$1 path
    shopt -s nullglob
    for path in "$prefix/bin"/*; do
        printf '%s\n' "${path##*/}"
    done | LC_ALL=C sort
    shopt -u nullglob
}

assert_bins() {
    local prefix=$1 expected=$2 actual="$work/actual"
    list_bins "$prefix" > "$actual"
    if ! cmp -s "$expected" "$actual"; then
        diff -u "$expected" "$actual" >&2 || true
        fail "unexpected binaries under $prefix/bin"
    fi
}

default_prefix="$work/default"
mkdir -p "$default_prefix"
(
    cd "$root"
    zig build -Doptimize=ReleaseFast --prefix "$default_prefix"
)

cat > "$work/default-expected" <<'EOF'
sketerm
sketerm-editor
sketerm-files
sketerm-mux
sketerm-viewer
sketerm-web
EOF

printf 'default zig-out/bin contents:\n'
while IFS= read -r binary; do
    printf '  %s\n' "$binary"
done < "$work/default-expected"
assert_bins "$default_prefix" "$work/default-expected"

printf '\033[31mgraph\033[0m\n' > "$work/replay.bin"
(
    cd "$root"
    zig build smoke-image -Doptimize=ReleaseFast --prefix "$default_prefix"
    zig build bench-editor -Doptimize=ReleaseFast --prefix "$default_prefix" -- --quick
    zig build replay -Doptimize=ReleaseFast --prefix "$default_prefix" -- "$work/replay.bin" 8 2
)
assert_bins "$default_prefix" "$work/default-expected"

(
    cd "$root"
    zig build lsp-stub -Doptimize=ReleaseFast --prefix "$default_prefix"
)
cat > "$work/lsp-expected" <<'EOF'
sketerm
sketerm-editor
sketerm-files
sketerm-lsp-stub
sketerm-mux
sketerm-viewer
sketerm-web
EOF
assert_bins "$default_prefix" "$work/lsp-expected"

printf 'PASS: default install is shipped-only; smoke/bench/replay and lsp-stub steps resolve their artifacts\n'
