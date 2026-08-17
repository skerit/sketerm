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

mkdir -p "$work/source" "$work/package"

# Start from tracked worktree files so neither ignored build products nor
# unrelated untracked files can satisfy an omitted package path.
git -C "$root" ls-files -z \
    | tar --null -C "$root" --files-from=- -cf - \
    | tar -C "$work/source" -xf -

package_name=$(zig fetch "$work/source" \
    --global-cache-dir "$work/fetch-cache")
archive="$work/fetch-cache/p/$package_name.tar.gz"
[ -f "$archive" ] || fail "zig fetch did not create $archive"

tar --strip-components=1 -xzf "$archive" -C "$work/package"
package="$work/package"
[ -f "$package/build.zig.zon" ] \
    || fail "fetched archive did not extract to $package"

vendor_entries=(
    aro_shims
    avdec_shim.c
    avenc_shim.c
    cef_root.h
    cimport_core.h
    cimport_root.h
    msf_gif.h
    stb_image_impl.c
    stb_image_write.h
    stb_image.h
    tree-sitter
    vpxenc_shim.c
    vtenc_shim.c
    x264_shim.c
    zstd
)

for entry in "${vendor_entries[@]}"; do
    [ -e "$package/vendor/$entry" ] \
        || fail "fetched archive omitted vendor/$entry"
done

shopt -s dotglob nullglob
for path in "$package/vendor"/*; do
    entry=${path##*/}
    case " ${vendor_entries[*]} " in
        *" $entry "*) ;;
        *) fail "fetched archive unexpectedly included vendor/$entry" ;;
    esac
done
shopt -u dotglob nullglob

dist_entries=(
    test-test-roots.sh
)

for entry in "${dist_entries[@]}"; do
    [ -f "$package/dist/$entry" ] \
        || fail "fetched archive omitted dist/$entry"
done

shopt -s dotglob nullglob
for path in "$package/dist"/*; do
    entry=${path##*/}
    case " ${dist_entries[*]} " in
        *" $entry "*) ;;
        *) fail "fetched archive unexpectedly included dist/$entry" ;;
    esac
done
shopt -u dotglob nullglob

for excluded in .git .zig-cache zig-cache zig-out zig-pkg; do
    [ ! -e "$package/$excluded" ] \
        || fail "fetched archive unexpectedly included $excluded"
done

run_build() {
    (
        cd "$package"
        zig build "$@" -Doptimize=ReleaseFast \
            --cache-dir "$work/build-cache" \
            --global-cache-dir "$work/build-global-cache" \
            --prefix "$work/prefix"
    )
}

run_build mux
run_build mux-client-check
run_build test-core

gui_pkgs=(
    gtk4
    libadwaita-1
    freetype2
    harfbuzz
    epoxy
    fribidi
    fontconfig
    x11
    libpulse
    libpulse-mainloop-glib
    vpx
)
if pkg-config --exists "${gui_pkgs[@]}"; then
    run_build test
    run_build install
else
    printf 'SKIP: fetched archive GUI build dependencies are unavailable\n'
fi

cef_include=${CEF_INCLUDE:-/usr/include/cef}
cef_lib=${CEF_LIB:-/usr/lib/cef}
if [ -f "$cef_include/include/capi/cef_app_capi.h" ] \
        && [ -f "$cef_lib/libcef.so" ]; then
    run_build web \
        -Dcef-include="$cef_include" \
        -Dcef-lib="$cef_lib"
    run_build test-web \
        -Dcef-include="$cef_include" \
        -Dcef-lib="$cef_lib"
else
    printf 'SKIP: fetched archive CEF build dependencies are unavailable\n'
fi

printf 'PASS: fetched Zig package archive is complete and builds in isolation\n'
