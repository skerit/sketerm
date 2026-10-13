#!/usr/bin/env bash
# Every environment removal goes through `env.unset` (src/util/env.zig).
# libc's unsetenv compacts the startup environ array in place, and Zig's std
# keeps a fixed-length view of that array which it scans on the first stderr
# print: a raw removal leaves a NULL inside the view and the process SEGVs.

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
home="src/util/env.zig"
pattern='\.unsetenv[[:space:]]*\('

cd "$root"
own=$(grep -cE "$pattern" "$home" || true)
if [[ $own -ne 1 ]]; then
    printf 'FAIL: expected exactly one raw unsetenv in %s (inside env.unset), found %s; the gate pattern no longer matches\n' "$home" "$own" >&2
    exit 1
fi
hits=$(grep -rnE --include='*.zig' "$pattern" src | grep -v "^$home:" || true)
if [[ -n $hits ]]; then
    printf 'FAIL: raw unsetenv outside %s; call env.unset instead:\n%s\n' "$home" "$hits" >&2
    exit 1
fi
printf 'PASS: every environment removal goes through env.unset\n'
