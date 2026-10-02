#!/usr/bin/env bash
# Supply a real local DNS resolver without changing any host namespace or config.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
for dependency in unshare mount ip python3; do
    if ! command -v "$dependency" >/dev/null; then
        printf 'FAIL: local DNS namespace wrapper requires %s\n' "$dependency" >&2
        exit 1
    fi
done
exec python3 -B "$here/web_untrusted_fixtures.py" netns "$@"
