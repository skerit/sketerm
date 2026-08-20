#!/bin/sh
# Assemble the macOS .app bundle the CEF browser helper needs to run.
#
# This is NOT cosmetic packaging. macOS CEF does not work without it,
# and each piece below answers a specific runtime failure observed on
# macOS 26 / CEF 151:
#
#   no bundle at all        -> "icudtl.dat not found in bundle", then
#                              cef_initialize fails. Chromium resolves
#                              its resources through the FRAMEWORK
#                              bundle, which it can only find from a
#                              bundled main executable.
#   no helper .app          -> "GPU process launch failed:
#                              error_code=1003" repeatedly, then
#                              "GPU process isn't usable. Goodbye."
#                              Children may not be launched by
#                              re-executing the browser binary the way
#                              Linux does; they need their own bundle
#                              (and their own Info.plist, so they take
#                              no dock icon).
#   flat framework          -> rejected by macOS 26 / Xcode 26, which
#                              want the VERSIONED layout (Versions/A +
#                              relative symlinks). `zig build fetch-cef`
#                              already lays the cached distribution out
#                              that way; this script preserves it.
#
# Usage:
#   dist/macos-bundle.sh <out-dir> <webengine-exe> <cef-release-dir> [--copy]
#
# By default the framework is SYMLINKED into the bundle, which is what
# a dev loop wants (it is 224MB). Pass --copy for a shippable bundle.
set -eu

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[ $# -ge 3 ] || usage
out="$1"
exe="$2"
release="$3"
mode="${4:-}"

name="sketerm-webengine"
helper="$name Helper"
fw="Chromium Embedded Framework.framework"

[ -x "$exe" ] || { echo "macos-bundle: no executable at $exe" >&2; exit 1; }
[ -d "$release/$fw" ] || { echo "macos-bundle: no framework at $release/$fw" >&2; exit 1; }

app="$out/$name.app"
helper_app="$app/Contents/Frameworks/$helper.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
mkdir -p "$helper_app/Contents/MacOS"

# One binary, two identities. The helper is the SAME program: it takes
# CEF's own command line, returns from cef_execute_process as a child,
# and never reaches our socket loop. Copied rather than symlinked
# because a symlinked executable inside a bundle confuses code signing.
cp "$exe" "$app/Contents/MacOS/$name"
cp "$exe" "$helper_app/Contents/MacOS/$helper"

# LSUIElement on the helper is what keeps renderer/GPU children out of
# the Dock; without it every child process bounces an icon.
plist() {
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSHighResolutionCapable</key><true/>
$4
</dict>
</plist>
EOF
}

plist "$app/Contents/Info.plist" "$name" "dev.sker.sketerm.webengine" ""
plist "$helper_app/Contents/Info.plist" "$helper" "dev.sker.sketerm.webengine.helper" \
    "  <key>LSUIElement</key><true/>"

if [ "$mode" = "--copy" ]; then
    cp -a "$release/$fw" "$app/Contents/Frameworks/$fw"
else
    ln -s "$release/$fw" "$app/Contents/Frameworks/$fw"
fi

# The framework's install name is @executable_path/../Frameworks/…,
# which is correct for the MAIN executable in Contents/MacOS and wrong
# for the helper: from Contents/Frameworks/<helper>.app/Contents/MacOS
# it resolves inside the HELPER's bundle, where no framework exists
# ("Library not loaded: … (no such file)", then every child dies and the
# browser gives up with "GPU process isn't usable"). The framework sits
# three levels up from there, which is the same relative path CEF's own
# CefScopedLibraryLoader uses for helpers.
old="@executable_path/../Frameworks/$fw/Chromium Embedded Framework"
new="@executable_path/../../../$fw/Chromium Embedded Framework"
install_name_tool -change "$old" "$new" "$helper_app/Contents/MacOS/$helper"

# install_name_tool invalidates the signature it just edited around, and
# macOS refuses to exec a binary whose signature does not match. Ad-hoc
# is enough to run locally; a distributable bundle wants a real identity
# (see docs/macos-winstream-setup.md for how that is handled elsewhere).
codesign --force --sign - "$helper_app/Contents/MacOS/$helper" 2>/dev/null || {
    echo "macos-bundle: codesign failed for the helper" >&2
    exit 1
}

echo "macos-bundle: $app"
