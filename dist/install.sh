#!/usr/bin/env bash
# Build the checked-out repo and install it, every time.
#
# Exists because plain `makepkg -si` silently does not install when the
# package file for HEAD is already present: pkgver() derives from HEAD,
# uncommitted changes do not move it, so makepkg reports "A package has
# already been built", exits 13, and leaves the old binary installed.
# Passing -f is the normal case here, so this wrapper hardcodes it.
#
# Any extra arguments are forwarded to makepkg.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
exec makepkg -sif "$@"
