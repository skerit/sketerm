#!/usr/bin/env bash
# Build the checked-out repo and install it, every time.
#
# Arch/derivatives go through makepkg + the PKGBUILD next to this file.
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
#   ./install.sh --deps          print/install the build dependencies
#   ./install.sh --prefix DIR    plain-install prefix (default /usr/local)
#   ./install.sh --no-install    build and stage the package, do not install
#
# On the Arch path any unrecognised argument is forwarded to makepkg.

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")

# The GUI calls into APIs that landed in these releases; below them it
# does not compile at all (missing symbols, not deprecation warnings).
# Bump these together with whatever new call made them necessary.
GTK_MIN=4.14
ADW_MIN=1.4
GLIB_MIN=2.74

mode=auto          # auto | mux | gui
prefix=/usr/local
do_install=1
want_deps=0
makepkg_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --mux-only)   mode=mux ;;
        --gui-only)   mode=gui ;;
        --deps)       want_deps=1 ;;
        --no-install) do_install=0 ;;
        --prefix)     prefix="$2"; shift ;;
        --prefix=*)   prefix="${1#*=}" ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *)            makepkg_args+=("$1") ;;
    esac
    shift
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Sort-based ">=" so 4.9 does not compare above 4.14.
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# ---------------------------------------------------------------- version

pkg_version() {
    local ver
    ver=$(grep -m1 '\.version' "$root/build.zig.zon" | sed -E 's/.*"([^"]+)".*/\1/')
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '%s.r%s.g%s' "$ver" \
            "$(git -C "$root" rev-list --count HEAD)" \
            "$(git -C "$root" rev-parse --short=7 HEAD)"
    else
        printf '%s' "$ver"
    fi
}

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

# --------------------------------------------------------------- build deps

DEB_BUILD_DEPS=(
    build-essential pkg-config ncurses-bin
    libgtk-4-dev libadwaita-1-dev libfreetype6-dev libharfbuzz-dev
    libepoxy-dev libfribidi-dev libfontconfig1-dev libvpx-dev libpulse-dev
)
# The daemon links libc only, so a mux-only build needs no -dev packages
# beyond a compiler driver and tic for the terminfo entry.
DEB_BUILD_DEPS_MUX=(build-essential ncurses-bin)

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

build_all() {
    command -v zig >/dev/null 2>&1 || die "zig is not installed (this project pins Zig 0.16)"
    cd "$root"
    if [ "$1" = gui ]; then
        # Normal builds runtime-load Opus automatically.
        say "building GUI + daemon"
        zig build -Doptimize=ReleaseFast
    else
        say "building daemon only"
        zig build mux -Doptimize=ReleaseFast
    fi
    # The portable daemon compiles the Opus probe out and stays
    # static/codec-free by design; it is what gets scp'd to servers.
    zig build mux-portable -Doptimize=ReleaseFast
}

# ------------------------------------------------------------------ stage
#
# Lays the install tree out under $1 (a fake root). Identical layout to
# the PKGBUILD's package(), so the two packagings cannot drift apart.

stage() {
    local dest=$1 kind=$2
    cd "$root"

    install -Dm755 zig-out/bin/sketerm-mux "$dest/usr/bin/sketerm-mux"
    install -Dm755 zig-out/bin/sketerm-mux-portable \
        "$dest/usr/lib/sketerm/sketerm-mux-portable"

    if [ "$kind" = gui ]; then
        # The file manager is the SAME executable under its own name
        # (argv[0] dispatch): a distinct binary + cmdline is what keeps
        # Plasma's taskbar from merging the two apps. Hardlinked so the
        # package does not ship the binary twice.
        install -Dm755 zig-out/bin/sketerm "$dest/usr/bin/sketerm"
        ln -f "$dest/usr/bin/sketerm" "$dest/usr/bin/sketerm-files"
        ln -f "$dest/usr/bin/sketerm" "$dest/usr/bin/sketerm-viewer"

        install -Dm644 data/dev.sker.sketerm.desktop \
            "$dest/usr/share/applications/dev.sker.sketerm.desktop"
        install -Dm644 data/dev.sker.sketerm.files.desktop \
            "$dest/usr/share/applications/dev.sker.sketerm.files.desktop"
        install -Dm644 data/dev.sker.sketerm.viewer.desktop \
            "$dest/usr/share/applications/dev.sker.sketerm.viewer.desktop"

        local i
        for i in dev.sker.sketerm dev.sker.sketerm.files dev.sker.sketerm.viewer; do
            install -Dm644 "data/icons/hicolor/scalable/apps/$i.svg" \
                "$dest/usr/share/icons/hicolor/scalable/apps/$i.svg"
        done
        for i in sketerm-terminal-symbolic sketerm-split-left-right-symbolic \
                 sketerm-split-top-bottom-symbolic sketerm-rendering-symbolic \
                 sketerm-preview-pane-symbolic; do
            install -Dm644 "data/icons/hicolor/scalable/actions/$i.svg" \
                "$dest/usr/share/icons/hicolor/scalable/actions/$i.svg"
        done

        install -Dm644 data/sample.layout "$dest/usr/share/sketerm/sample.layout"

        # Ready-made CRT shaders (custom_shader / "Pane Shader...").
        # Per-file licensing (all GPL-3-compatible) -- see the README.
        for i in crt crt-lottes crt-easymode zfast-crt; do
            install -Dm644 "data/shaders/$i.glsl" \
                "$dest/usr/share/sketerm/shaders/$i.glsl"
        done
        install -Dm644 data/shaders/README "$dest/usr/share/sketerm/shaders/README"
    fi

    install -Dm644 LICENSE "$dest/usr/share/licenses/sketerm/LICENSE"
    install -Dm644 data/sample.conf "$dest/usr/share/sketerm/sample.conf"

    # Shell-integration scripts + auto-injection shims. The daemon owns
    # every PTY, so these ship with the mux-only install too: zsh/fish
    # are injected at spawn, bash users source sketerm.bash themselves.
    install -Dm644 data/shell-integration/sketerm.bash \
        "$dest/usr/share/sketerm/shell-integration/sketerm.bash"
    install -Dm644 data/shell-integration/sketerm.zsh \
        "$dest/usr/share/sketerm/shell-integration/sketerm.zsh"
    install -Dm644 data/shell-integration/sketerm.fish \
        "$dest/usr/share/sketerm/shell-integration/sketerm.fish"
    install -Dm644 data/shell-integration/zsh/.zshenv \
        "$dest/usr/share/sketerm/shell-integration/zsh/.zshenv"
    install -Dm644 data/shell-integration/bash/sketerm-rc.bash \
        "$dest/usr/share/sketerm/shell-integration/bash/sketerm-rc.bash"
    install -Dm644 data/shell-integration/fish-xdg/fish/vendor_conf.d/sketerm.fish \
        "$dest/usr/share/sketerm/shell-integration/fish-xdg/fish/vendor_conf.d/sketerm.fish"

    # Compile + install the terminfo entry system-wide so
    # $TERM=sketerm-256color resolves without per-user setup.
    #
    # The SYSTEM tic is required, not merely the first one on PATH: a
    # conda/homebrew ncurses writes hex-named directories (73/sketerm-*)
    # and Debian's reader only ever looks in the letter directory (s/),
    # so a foreign tic produces an entry that silently never resolves.
    local tic_bin=""
    if [ -x /usr/bin/tic ]; then
        tic_bin=/usr/bin/tic
    elif command -v tic >/dev/null 2>&1; then
        tic_bin=$(command -v tic)
        warn "using $tic_bin; if TERM=sketerm-256color does not resolve, install ncurses-bin"
    fi
    if [ -n "$tic_bin" ]; then
        install -d "$dest/usr/share/terminfo"
        "$tic_bin" -x -o "$dest/usr/share/terminfo" terminfo/sketerm-256color.src
    else
        warn "tic not found (install ncurses-bin); skipping terminfo entry"
    fi
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
            [ -n "$pkg" ] && printf '%s\n' "$pkg"
        done | sort -u | paste -sd', ' -
}

do_debian() {
    local kind=$1 ver arch pkgname deps stagedir debfile
    ver=$(pkg_version)
    arch=$(dpkg --print-architecture)

    # Distinct package names so a mux-only install and a full install do
    # not silently claim each other's file list.
    if [ "$kind" = gui ]; then pkgname=sketerm; else pkgname=sketerm-mux; fi

    stagedir=$(mktemp -d)
    trap 'rm -rf "$stagedir"' RETURN

    stage "$stagedir" "$kind"

    deps=$(deb_depends_of "$stagedir/usr/bin/sketerm-mux")
    if [ "$kind" = gui ]; then
        deps="$deps, $(deb_depends_of "$stagedir/usr/bin/sketerm")"
    fi
    # Collapse duplicates introduced by concatenating the two lists.
    deps=$(printf '%s' "$deps" | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
           | grep -v '^$' | sort -u | paste -sd', ' -)

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
            echo "Recommends: libopus0, libglycin-2-0, glycin-loaders"
        else
            echo "Recommends: libopus0"
        fi
        echo "Suggests: libtesseract-dev"
        echo "Homepage: https://github.com/skerit/sketerm"
        if [ "$kind" = gui ]; then
            echo "Provides: sketerm-mux"
            echo "Conflicts: sketerm-mux"
            echo "Replaces: sketerm-mux"
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

do_plain() {
    local kind=$1 stagedir
    stagedir=$(mktemp -d)
    trap 'rm -rf "$stagedir"' RETURN
    stage "$stagedir" "$kind"

    if [ "$do_install" -eq 0 ]; then
        say "staged in $stagedir (not installed)"
        # Caller asked for no install, so hand back the tree instead of
        # deleting it on return.
        trap - RETURN
        return
    fi

    say "installing into $prefix (no package manager involvement)"
    as_root cp -a "$stagedir/usr/." "$prefix/"
}

# ----------------------------------------------------------------- driver

probe_gui

case "$mode" in
    gui)
        [ "$gui_ok" -eq 1 ] || die "GUI build not possible here: $gui_why"
        kind=gui ;;
    mux)
        kind=mux ;;
    auto)
        if [ "$gui_ok" -eq 1 ]; then
            kind=gui
        else
            kind=mux
            warn "$gui_why"
            warn "building the sketerm-mux daemon only; pass --gui-only to make this fatal"
        fi ;;
esac

if command -v makepkg >/dev/null 2>&1 && [ "$mode" != mux ] && [ "$kind" = gui ]; then
    say "Arch detected, delegating to makepkg"
    cd "$here"
    exec makepkg -sif "${makepkg_args[@]}"
fi

if command -v dpkg-deb >/dev/null 2>&1; then
    if [ "$want_deps" -eq 1 ]; then
        if [ "$kind" = gui ]; then
            install_deb_deps DEB_BUILD_DEPS
        else
            install_deb_deps DEB_BUILD_DEPS_MUX
        fi
        # Dependencies can turn a mux-only verdict into a GUI one.
        probe_gui
        [ "$mode" = auto ] && [ "$gui_ok" -eq 1 ] && kind=gui
    fi
    build_all "$kind"
    do_debian "$kind"
else
    warn "no makepkg and no dpkg-deb; falling back to a plain install"
    build_all "$kind"
    do_plain "$kind"
fi

say "done"
if [ "$kind" = mux ]; then
    say "installed: sketerm-mux (daemon). The GUI was not built."
fi

# vim:set ts=4 sw=4 et:
