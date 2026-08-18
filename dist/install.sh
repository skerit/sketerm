#!/usr/bin/env bash
# Build the checked-out repo and install it, every time.
#
# Arch-compatible hosts with makepkg + pacman use the PKGBUILD next to this file.
# Debian/Ubuntu and anything else with dpkg get a .deb built here and
# installed with dpkg -i, so the install is tracked and removable.
# Everything else falls back to a plain install into a prefix.
#
# The Arch path passes -f deliberately: pkgver() derives the version
# from HEAD, so rebuilding the same commit produces a package file that
# already exists, and makepkg then refuses with "A package has already
# been built" and exits WITHOUT installing -- leaving the previously
# installed binary in place. Uncommitted source changes do not move
# pkgver either, so -f is the normal case, not the exception.
#
# Usage:
#   ./install.sh                 build + install everything available
#   ./install.sh --mux-only      only sketerm-mux (no GTK needed at all)
#   ./install.sh --gui-only      fail rather than silently dropping the GUI
#   ./install.sh --deps          install package-manager build dependencies
#   ./install.sh --prefix DIR    plain-install prefix (default /usr/local)
#   ./install.sh --no-install    build the package, but do not install it
#   ./install.sh -- ARGS...      pass approved build options to makepkg
#
# The Arch passthrough accepts exact non-relocating build options only; run
# --help for the contract. Other backends reject all passthrough arguments.

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
source "$here/stage.sh"

# The GUI calls into APIs that landed in these releases; below them it
# does not compile at all (missing symbols, not deprecation warnings).
# Bump these together with whatever new call made them necessary.
GTK_MIN=4.14
ADW_MIN=1.4
GLIB_MIN=2.74
ZIG_MIN=0.16.0
ZIG_MAX=0.17.0
CEF_INCLUDE=${CEF_INCLUDE:-/usr/include/cef}
CEF_LIB=${CEF_LIB:-/usr/lib/cef}

mode=auto          # auto | mux | gui
prefix=/usr/local
want_prefix=0
do_install=1
want_deps=0
makepkg_args=()

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --mux-only)
            [ "$mode" != gui ] || die "--mux-only and --gui-only are mutually exclusive"
            mode=mux ;;
        --gui-only)
            [ "$mode" != mux ] || die "--mux-only and --gui-only are mutually exclusive"
            mode=gui ;;
        --deps)       want_deps=1 ;;
        --no-install) do_install=0 ;;
        --prefix)
            [ $# -gt 1 ] && [ -n "$2" ] && [[ "$2" != -* ]] \
                || die "--prefix requires a directory argument"
            prefix="$2"; want_prefix=1; shift ;;
        --prefix=*)
            prefix="${1#*=}"
            [ -n "$prefix" ] || die "--prefix requires a non-empty directory argument"
            want_prefix=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            cat <<'EOF'
Arch makepkg passthrough accepts only these exact options:
  -A -c -C -e -f -L -m (bundles allowed, for example -cLm)
  --ignorearch --clean --cleanbuild --noextract --force --log --nocolor
  --check --holdver --nocheck --noprepare --nosign --sign
  --skipchecksums --skipinteg --skippgpcheck --noconfirm --noprogressbar
  --key KEY, --key=KEY

Long-option abbreviations, positional/environment arguments, sourced --config,
-D/--dir, and -p are rejected. The installer always selects dist/PKGBUILD.
--no-install still uses makepkg -s, which may install missing dependencies.
On Arch-compatible hosts --deps is redundant because makepkg always receives -s.
On dpkg hosts --deps does not install Zig; install Zig 0.16.x separately.
EOF
            exit 0 ;;
        --)            shift; makepkg_args+=("$@"); break ;;
        *)            makepkg_args+=("$1") ;;
    esac
    shift
done

validate_makepkg_args() {
    local i arg
    for ((i = 0; i < ${#makepkg_args[@]}; i++)); do
        arg=${makepkg_args[i]}
        if [[ "$arg" != --* ]] \
                && [[ "${arg#-}" == *D* || "${arg#-}" == *p* ]]; then
            die "source-relocating makepkg options -D/--dir and -p are not supported"
        fi
        case "$arg" in
            --d|--d=*|--di|--di=*|--dir|--dir=*)
                die "source-relocating makepkg options -D/--dir and -p are not supported" ;;
            --ignorearch|--clean|--cleanbuild|--noextract|--force|--log|--nocolor|\
            --check|--holdver|--nocheck|--noprepare|--nosign|--sign|\
            --skipchecksums|--skipinteg|--skippgpcheck|--noconfirm|--noprogressbar)
                ;;
            --key)
                ((i + 1 < ${#makepkg_args[@]})) \
                    || die "$arg requires an argument"
                ((i += 1)) ;;
            --key=*)
                ;;
            -*)
                [[ "$arg" =~ ^-[AcCefLm]+$ ]] \
                    || die "unsupported makepkg option $arg; use exact options listed by --help" ;;
            *)
                die "makepkg positional and environment arguments are not supported: $arg" ;;
        esac
    done
}

validate_makepkg_args

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Sort-based ">=" so 4.9 does not compare above 4.14.
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

check_zig() {
    local have
    command -v zig >/dev/null 2>&1 \
        || die "zig is not installed; install Zig 0.16.x before building"
    have=$(zig version) || die "could not determine the installed Zig version"
    if ! version_ge "$have" "$ZIG_MIN" || version_ge "$have" "$ZIG_MAX"; then
        die "Zig $have is unsupported; this checkout requires Zig 0.16.x"
    fi
}

# ---------------------------------------------------------------- version
#
# Shared with PKGBUILD's pkgver() so the semver has one derivation as well as
# one source of truth (.version in build.zig.zon).

pkg_version() { sketerm_pkgver "$root"; }

# ------------------------------------------------------------ gui support

# Sets gui_ok / gui_why. A missing pkg-config module and a too-old one
# are both "no GUI", but the message has to say which, or the user
# installs -dev packages that were never the problem.
probe_gui() {
    gui_ok=1; gui_why=""
    command -v pkg-config >/dev/null 2>&1 || { gui_ok=0; gui_why="pkg-config not installed"; return; }

    local mod min have
    for spec in "gtk4:$GTK_MIN" "libadwaita-1:$ADW_MIN" "glib-2.0:$GLIB_MIN" \
                "freetype2:0" "harfbuzz:0" "epoxy:0" "fribidi:0" \
                "fontconfig:0" "vpx:0" "libpulse:0" "libpulse-mainloop-glib:0"; do
        mod=${spec%:*}; min=${spec##*:}
        if ! have=$(pkg-config --modversion "$mod" 2>/dev/null); then
            gui_ok=0; gui_why="$mod development files missing"; return
        fi
        if [ "$min" != 0 ] && ! version_ge "$have" "$min"; then
            gui_ok=0; gui_why="$mod is $have, the GUI needs >= $min"; return
        fi
    done
}

probe_web() {
    web_ok=0
    web_why="CEF headers or runtime not found (set CEF_INCLUDE and CEF_LIB for a system CEF install)"
    [ -f "$CEF_INCLUDE/include/capi/cef_app_capi.h" ] || return 0
    [ -f "$CEF_LIB/libcef.so" ] || return 0
    web_ok=1
    web_why=""
}

# --------------------------------------------------------------- build deps

DEB_BUILD_DEPS=(
    build-essential pkg-config ncurses-bin
    libgtk-4-dev libadwaita-1-dev libglib2.0-dev libfreetype6-dev libharfbuzz-dev
    libepoxy-dev libfribidi-dev libfontconfig1-dev libvpx-dev libpulse-dev
)
# Debian releases do not consistently provide the pinned Zig toolchain, so
# --deps installs only distro-provided prerequisites. check_zig() gives the
# exact requirement instead of asking apt for an unavailable package/version.
# The shipped daemon links libc only, but both daemon builds translate the
# core header containing fribidi.h. pkg-config and libfribidi-dev are therefore
# build-time requirements even though the unused native link is dropped and
# mux-portable deliberately does not link fribidi.
DEB_BUILD_DEPS_MUX=(build-essential pkg-config ncurses-bin libfribidi-dev)

install_deb_deps() {
    local -n list=$1
    local missing=()
    local p
    for p in "${list[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$' \
            || missing+=("$p")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        say "build dependencies already satisfied"
        return
    fi
    say "installing build dependencies: ${missing[*]}"
    as_root apt-get update
    as_root apt-get install -y "${missing[@]}"
}

# ------------------------------------------------------------------ build
#
# Shared with PKGBUILD's build(); only the CEF paths differ (probed env vars
# here, distro literals there).

build_all() {
    check_zig
    sketerm_build "$root" "$1" "$web_ok" "$CEF_INCLUDE" "$CEF_LIB" "$web_why" "$2"
}

# The remote-deployment artifact has a fixed target list; everything else
# builds on any Linux architecture. Sets portable_ok, and warns once here so
# the omission is stated in installer terms rather than only build terms.
probe_portable() {
    # stderr suppressed: the build path names the architecture and the
    # supported list a moment later, from the one place that owns them.
    if sketerm_portable_target_for_arch "$1" >/dev/null 2>/dev/null; then
        portable_ok=1
    else
        portable_ok=0
        warn "packaging without sketerm-mux-portable; remote hosts reached with"
        warn "\`sketerm ssh\`/\`sketerm mux <host>\` must have sketerm-mux installed already"
    fi
}

# ------------------------------------------------------------------ stage
#
# Selects the host terminfo compiler, then calls the staging implementation
# shared with PKGBUILD.package().

stage() {
    local dest=$1 kind=$2 service_prefix=${3:-/usr} tic_bin=${SKETERM_TIC:-}
    local with_portable=${portable_ok:-1}
    if [ -n "$tic_bin" ]; then
        [ -x "$tic_bin" ] || die "SKETERM_TIC is not executable: $tic_bin"
    elif [ -x /usr/bin/tic ]; then
        tic_bin=/usr/bin/tic
    elif command -v tic >/dev/null 2>&1; then
        tic_bin=$(command -v tic)
        warn "using $tic_bin; if TERM=sketerm-256color does not resolve, install ncurses-bin"
    fi
    if [ -z "$tic_bin" ]; then
        warn "tic not found (install ncurses-bin); skipping terminfo entry"
    fi
    sketerm_stage "$root" "$dest" "$kind" "$web_ok" "$tic_bin" sketerm \
        "$service_prefix" "$with_portable"
}

# ------------------------------------------------------------- debian path

# Resolve a binary's real shared-library dependencies to package names.
# Hardcoding a list here rots across releases (libvpx7 vs libvpx9), and
# dlopen'd optionals (libopus, libtesseract, EGL) must NOT appear --
# they are probed at runtime and their absence is a supported state.
deb_depends_of() {
    local bin=$1 lib pkg
    { ldd "$bin" 2>/dev/null || true; } \
        | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) { print $i; break } }' \
        | while read -r lib; do
            pkg=$(dpkg -S "$lib" 2>/dev/null | head -1 | cut -d: -f1) || true
            if [ -z "$pkg" ]; then
                pkg=$(dpkg -S "$(readlink -f "$lib")" 2>/dev/null | head -1 | cut -d: -f1) || true
            fi
            # "[ -n ] && printf" would leave the loop with status 1 when the
            # LAST library is dpkg-unowned (e.g. a hand-installed libcef.so),
            # and pipefail would then kill the script without a message.
            if [ -n "$pkg" ]; then printf '%s\n' "$pkg"; fi
        done | sort -u | paste -sd, - | sed 's/,/, /g'
}

do_debian() {
    local kind=$1 arch=$2 ver pkgname deps stagedir debfile
    ver=$(pkg_version)

    # Distinct package names so a mux-only install and a full install do
    # not silently claim each other's file list.
    if [ "$kind" = gui ]; then pkgname=sketerm; else pkgname=sketerm-mux; fi

    stagedir=$(mktemp -d)
    trap 'rm -rf "$stagedir"' RETURN

    stage "$stagedir" "$kind"

    deps=$(deb_depends_of "$stagedir/usr/bin/sketerm-mux")
    if [ "$kind" = gui ]; then
        deps="$deps, $(deb_depends_of "$stagedir/usr/bin/sketerm")"
        if [ -x "$stagedir/usr/bin/sketerm-webengine" ]; then
            deps="$deps, $(deb_depends_of "$stagedir/usr/bin/sketerm-webengine")"
        fi
    fi
    # Collapse duplicates introduced by concatenating the lists. paste's
    # delimiter cycles one CHARACTER at a time, so join explicitly to keep
    # every dependency separated by the Debian-required comma + space.
    deps=$(printf '%s' "$deps" | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
           | grep -v '^$' | sort -u | paste -sd, - | sed 's/,/, /g')

    install -d "$stagedir/DEBIAN"
    {
        echo "Package: $pkgname"
        echo "Version: ${ver}-1"
        echo "Architecture: $arch"
        echo "Maintainer: Jelle De Loecker <jelle@elevenways.be>"
        echo "Depends: $deps"
        # Runtime-dlopen'd, all optional by design: absent means the
        # feature degrades, never that the binary fails to start.
        if [ "$kind" = gui ]; then
            echo "Recommends: libopus0, libglycin-2-0, glycin-loaders, gstreamer1.0-plugins-good, gstreamer1.0-libav, gstreamer1.0-pipewire, ffmpeg"
        else
            echo "Recommends: libopus0"
        fi
        echo "Suggests: libtesseract-dev"
        echo "Homepage: https://github.com/skerit/sketerm"
        if [ "$kind" = gui ]; then
            echo "Provides: sketerm-mux"
            echo "Conflicts: sketerm-mux"
            echo "Replaces: sketerm-mux"
            if [ "$web_ok" -eq 0 ]; then
                echo "X-Sketerm-Webengine: omitted ($web_why)"
            fi
            echo "Description: Native GTK4 terminal emulator written in Zig"
            echo " Terminal emulator with a client-server core: every terminal is a"
            echo " session owned by the sketerm-mux daemon, so panes survive a GUI"
            echo " crash and reattach over SSH or UDP."
        else
            echo "Description: sketerm session daemon (durable terminal sessions)"
            echo " The sketerm-mux daemon owns the PTY, parser and authoritative"
            echo " screen for each session. Links libc only -- no GTK -- so it runs"
            echo " on headless servers that the sketerm GUI cannot be built on."
        fi
    } > "$stagedir/DEBIAN/control"

    debfile="$here/${pkgname}_${ver}-1_${arch}.deb"
    say "building $debfile"
    dpkg-deb --root-owner-group --build "$stagedir" "$debfile" >/dev/null

    if [ "$do_install" -eq 1 ]; then
        say "installing $pkgname"
        # dpkg alone fails on unsatisfied Depends; apt-get -f fixes it up.
        as_root dpkg -i "$debfile" || as_root apt-get -f install -y
    else
        say "staged only, not installed"
    fi
    printf '%s\n' "$debfile"
}

# -------------------------------------------------------------- plain path

PLAIN_MANIFEST_REL=share/sketerm/plain-install-manifest

plain_make_manifest() {
    local stagedir=$1 output=$2
    printf '# sketerm plain-install manifest v1\n' > "$output"
    (
        cd "$stagedir/usr"
        find . \( -type f -o -type l \) -printf '%P\n'
        printf '%s\n' "$PLAIN_MANIFEST_REL"
    ) | LC_ALL=C sort -u >> "$output"
}

plain_manifest_has() {
    grep -Fqx -- "$2" "$1"
}

plain_validate_managed_path() {
    local path=$1
    case "$path" in
        ''|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*|*$'\r'*) return 1 ;;
    esac
    case "$path" in
        bin/*|lib/*|share/*) return 0 ;;
        *) return 1 ;;
    esac
}

plain_remove_managed_path() {
    local path=$1 target dir
    plain_validate_managed_path "$path" \
        || die "unsafe path in plain-install manifest: $path"
    target="$prefix/$path"
    if [ -e "$target" ] || [ -L "$target" ]; then
        as_root rm -f -- "$target" \
            || die "could not remove obsolete managed file: $target"
    fi
    # The manifest lists files only, so emptied directories have nothing else
    # to drive their removal (share/sketerm/shaders survived every GUI ->
    # mux-only downgrade). rmdir refuses a directory that still holds
    # anything, so pruning upward can only reclaim what this install emptied.
    dir=${path%/*}
    while [ "$dir" != "$path" ] && [ -n "$dir" ]; do
        as_root rmdir -- "$prefix/$dir" 2>/dev/null || break
        path=$dir
        dir=${path%/*}
    done
}

plain_remove_obsolete() {
    local previous=$1 current=$2 path
    while IFS= read -r path || [ -n "$path" ]; do
        case "$path" in ''|\#*) continue ;; esac
        plain_validate_managed_path "$path" \
            || die "unsafe path in plain-install manifest: $path"
        if ! plain_manifest_has "$current" "$path"; then
            plain_remove_managed_path "$path"
        fi
    done < "$previous"
}

do_plain() {
    local kind=$1 stagedir new_manifest manifest manifest_tmp
    stagedir=$(mktemp -d)
    trap 'rm -rf "$stagedir"' RETURN
    stage "$stagedir" "$kind" "$prefix"

    if [ "$do_install" -eq 0 ]; then
        say "staged in $stagedir (not installed)"
        # Caller asked for no install, so hand back the tree instead of
        # deleting it on return.
        trap - RETURN
        return
    fi

    new_manifest="$stagedir/plain-install-manifest"
    plain_make_manifest "$stagedir" "$new_manifest"
    manifest="$prefix/$PLAIN_MANIFEST_REL"

    if [ -e "$manifest" ] || [ -L "$manifest" ]; then
        [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] \
            || die "plain-install manifest is not a readable regular file: $manifest"
        plain_remove_obsolete "$manifest" "$new_manifest"
    elif ! plain_manifest_has "$new_manifest" bin/sketerm-webengine \
            && { [ -e "$prefix/bin/sketerm-webengine" ] \
                 || [ -L "$prefix/bin/sketerm-webengine" ]; }; then
        # The manifest IS the ownership record, so with no manifest yet this
        # installer owns nothing in the prefix. It used to delete this one
        # legacy path unconditionally, which on --prefix /usr silently removed
        # the distro package's helper. Report it instead; a stale helper beside
        # a new GUI is a nuisance, deleting another package's file is not.
        warn "$prefix/bin/sketerm-webengine was not installed by this script and is left alone"
        warn "it may belong to a system package; remove it yourself if the GUI starts a stale browser helper"
    fi

    say "installing into $prefix (no package manager involvement)"
    as_root cp -a "$stagedir/usr/." "$prefix/" \
        || die "could not copy the staged install into $prefix"

    # Publish ownership last. A failed or interrupted copy therefore leaves
    # the previous manifest available for a safe retry.
    manifest_tmp="$manifest.new"
    as_root install -m644 "$new_manifest" "$manifest_tmp" \
        || die "could not stage the plain-install manifest: $manifest_tmp"
    if ! as_root mv -f -- "$manifest_tmp" "$manifest"; then
        as_root rm -f -- "$manifest_tmp" || true
        die "could not publish the plain-install manifest: $manifest"
    fi
}

# ----------------------------------------------------------------- driver

if command -v makepkg >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1 \
        && [ "$mode" != mux ]; then
    [ "$want_prefix" -eq 0 ] || die "--prefix applies only to plain installs without a package manager"
    check_zig
    say "Arch-compatible makepkg/pacman host detected, delegating to makepkg"
    cd "$here"
    if [ "$do_install" -eq 1 ]; then
        exec makepkg -sif "${makepkg_args[@]}"
    else
        exec makepkg -sf "${makepkg_args[@]}"
    fi
fi

if [ ${#makepkg_args[@]} -gt 0 ]; then
    die "makepkg passthrough arguments require an Arch-compatible GUI package build"
fi

select_kind() {
    case "$mode" in
        mux)
            kind=mux ;;
        gui)
            probe_gui
            [ "$gui_ok" -eq 1 ] || die "GUI build not possible here: $gui_why"
            kind=gui ;;
        auto)
            probe_gui
            if [ "$gui_ok" -eq 1 ]; then
                kind=gui
            else
                kind=mux
                warn "$gui_why"
                warn "building the sketerm-mux daemon only; pass --gui-only to make this fatal"
            fi ;;
    esac
    if [ "$kind" = gui ]; then probe_web; else web_ok=0; web_why=""; fi
}

if command -v dpkg-deb >/dev/null 2>&1; then
    [ "$want_prefix" -eq 0 ] || die "--prefix applies only to plain installs without a package manager"
    package_arch=$(dpkg --print-architecture) \
        || die "could not determine the Debian package architecture"
    probe_portable "$package_arch"
    if [ "$want_deps" -eq 1 ]; then
        check_zig
        if [ "$mode" = mux ]; then
            install_deb_deps DEB_BUILD_DEPS_MUX
        else
            install_deb_deps DEB_BUILD_DEPS
        fi
    fi
    select_kind
    build_all "$kind" "$package_arch"
    do_debian "$kind" "$package_arch"
else
    [ "$want_deps" -eq 0 ] \
        || die "--deps requires an Arch-compatible GUI package build or a dpkg-based host"
    warn "no makepkg and no dpkg-deb; falling back to a plain install"
    package_arch=$(uname -m) || die "could not determine the host architecture"
    probe_portable "$package_arch"
    select_kind
    if [ "$kind" = gui ]; then
        sketerm_validate_install_prefix "$prefix" \
            || die "plain-install prefix must be an absolute path free of newlines and control characters"
        while [ "$prefix" != / ] && [[ "$prefix" == */ ]]; do
            prefix=${prefix%/}
        done
    fi
    build_all "$kind" "$package_arch"
    do_plain "$kind"
fi

say "done"
if [ "$kind" = mux ]; then
    if [ "$do_install" -eq 1 ]; then
        say "installed: sketerm-mux (daemon). The GUI was not built."
    else
        say "built: sketerm-mux (daemon), not installed. The GUI was not built."
    fi
fi

# vim:set ts=4 sw=4 et:
