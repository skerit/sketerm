#!/usr/bin/env bash

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
