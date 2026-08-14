#!/usr/bin/env bash
#
# The package-independent half of every Linux backend: version derivation,
# the build recipe, and the install tree. Sourced by dist/install.sh and by
# dist/PKGBUILD (which sets $startdir before sourcing), so nothing here may
# assume install.sh's helpers, options or globals exist.

# Progress output through whichever caller's helpers exist: install.sh's
# say/warn, else makepkg's msg/warning, else plain text.
sketerm_say() {
    if declare -F say >/dev/null 2>&1; then say "$*"
    elif declare -F msg >/dev/null 2>&1; then msg "%s" "$*"
    else printf '==> %s\n' "$*"
    fi
}

sketerm_warn() {
    if declare -F warn >/dev/null 2>&1; then warn "$*"
    elif declare -F warning >/dev/null 2>&1; then warning "%s" "$*"
    else printf '==> WARNING: %s\n' "$*" >&2
    fi
}

# The one derivation of the semver whose one source of truth is .version in
# build.zig.zon. A non-git tree (release tarball) simply has no .r<n>.g<sha>.
sketerm_pkgver() {
    local root=$1 ver
    ver=$(grep -m1 '\.version' "$root/build.zig.zon" | sed -E 's/.*"([^"]+)".*/\1/')
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '%s.r%s.g%s' "$ver" \
            "$(git -C "$root" rev-list --count HEAD)" \
            "$(git -C "$root" rev-parse --short=7 HEAD)"
    else
        printf '%s' "$ver"
    fi
}

# The one build recipe. $web_ok gates the browser helper; $web_skip_reason is
# the caller's explanation for why it is off (empty when the caller never
# probes, i.e. the Arch package, which requires the distro cef outright).
sketerm_build() {
    local root=$1 kind=$2 web_ok=$3 cef_include=$4 cef_lib=$5 web_skip_reason=${6:-}
    cd "$root"

    if [ "$kind" = gui ]; then
        # Normal builds runtime-load Opus automatically.
        sketerm_say "building GUI + daemon"
        zig build -Doptimize=ReleaseFast
        if [ "$web_ok" -eq 1 ]; then
            # The browser helper is built against a SPLIT cef install (headers
            # and runtime in two places, unlike the single-tree upstream
            # tarball), so both halves are pointed at explicitly.
            # -Dcef-runtime-dir defaults to -Dcef-lib, which is already the
            # installed location, so the rpath and the LD_PRELOAD the helper
            # re-execs with are both correct in the package.
            sketerm_say "building browser helper"
            zig build web -Doptimize=ReleaseFast \
                -Dcef-include="$cef_include" \
                -Dcef-lib="$cef_lib"
        else
            sketerm_warn "$web_skip_reason; packaging browser identity without sketerm-webengine"
        fi
    else
        sketerm_say "building daemon only"
        zig build mux -Doptimize=ReleaseFast
    fi

    # The portable daemon compiles the Opus probe out and stays
    # static/codec-free by design; it is what gets scp'd to servers.
    zig build mux-portable -Doptimize=ReleaseFast
}

# Stage the package-independent install tree for every Linux backend.
sketerm_stage() {
    local root=$1 dest=$2 kind=$3 with_web=$4 tic_bin=$5 license_name=$6
    local i
    cd "$root"

    install -Dm755 zig-out/bin/sketerm-mux "$dest/usr/bin/sketerm-mux"
    install -Dm755 zig-out/bin/sketerm-mux-portable \
        "$dest/usr/lib/sketerm/sketerm-mux-portable"

    if [ "$kind" = gui ]; then
        install -Dm755 zig-out/bin/sketerm "$dest/usr/bin/sketerm"
        for i in files viewer editor web; do
            ln -f "$dest/usr/bin/sketerm" "$dest/usr/bin/sketerm-$i"
        done

        if [ "$with_web" -eq 1 ]; then
            install -Dm755 zig-out/bin/sketerm-webengine \
                "$dest/usr/bin/sketerm-webengine"
        fi

        for i in dev.sker.sketerm dev.sker.sketerm.files dev.sker.sketerm.viewer \
                 dev.sker.sketerm.editor dev.sker.sketerm.web; do
            install -Dm644 "data/$i.desktop" \
                "$dest/usr/share/applications/$i.desktop"
            install -Dm644 "data/icons/hicolor/scalable/apps/$i.svg" \
                "$dest/usr/share/icons/hicolor/scalable/apps/$i.svg"
        done
        for i in sketerm-terminal-symbolic sketerm-split-left-right-symbolic \
                 sketerm-split-top-bottom-symbolic sketerm-rendering-symbolic \
                 sketerm-preview-pane-symbolic sketerm-reader-symbolic; do
            install -Dm644 "data/icons/hicolor/scalable/actions/$i.svg" \
                "$dest/usr/share/icons/hicolor/scalable/actions/$i.svg"
        done

        install -Dm644 data/sketerm.portal \
            "$dest/usr/share/xdg-desktop-portal/portals/sketerm.portal"
        install -Dm644 data/org.freedesktop.impl.portal.desktop.sketerm.service \
            "$dest/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service"
        install -Dm644 data/sample.layout "$dest/usr/share/sketerm/sample.layout"

        for i in crt crt-lottes crt-easymode zfast-crt; do
            install -Dm644 "data/shaders/$i.glsl" \
                "$dest/usr/share/sketerm/shaders/$i.glsl"
        done
        install -Dm644 data/shaders/README "$dest/usr/share/sketerm/shaders/README"
    fi

    install -Dm644 LICENSE "$dest/usr/share/licenses/$license_name/LICENSE"
    install -Dm644 data/sample.conf "$dest/usr/share/sketerm/sample.conf"

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

    if [ -n "$tic_bin" ]; then
        install -d "$dest/usr/share/terminfo"
        "$tic_bin" -x -o "$dest/usr/share/terminfo" terminfo/sketerm-256color.src
    fi
}
