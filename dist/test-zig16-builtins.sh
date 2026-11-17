#!/usr/bin/env bash
# No builtin that exists only on Zig 0.17. The tree builds on 0.16 AND 0.17,
# and 0.17's `zig fmt` silently rewrites `@intFromEnum` to `@backingInt` and
# `@enumFromInt` to `@fromBackingInt` (measured with 0.17.1, 2026-11-17: 712
# and 122 sites in src/), which 0.16 rejects as "invalid builtin function".
# Format with 0.16's `zig fmt`, or undo exactly those rewrites.

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
pattern='@(backingInt|fromBackingInt)[[:space:]]*\('

cd "$root"
hits=$(grep -rnE --include='*.zig' "$pattern" src build.zig || true)
if [[ -n $hits ]]; then
    printf 'FAIL: Zig 0.17-only builtins (0.17 zig fmt writes them; 0.16 cannot compile them). Use @intFromEnum / @enumFromInt:\n%s\n' "$hits" >&2
    exit 1
fi
printf 'PASS: no Zig 0.17-only builtins (@backingInt, @fromBackingInt)\n'
