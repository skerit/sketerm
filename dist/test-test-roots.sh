#!/usr/bin/env bash

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
src="$root/src"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

read_imports() {
    local file=$1 line
    while IFS= read -r line; do
        if [[ $line =~ @import\(\"([^\"]+\.zig)\"\) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done < "$file"
}

write_imports() {
    local root_file=$1 output=$2 duplicates
    duplicates="$output.duplicates"
    read_imports "$root_file" | LC_ALL=C sort > "$output"
    LC_ALL=C uniq -d "$output" > "$duplicates"
    if [[ -s $duplicates ]]; then
        fail "duplicate direct imports in ${root_file#"$root/"}: $(tr '\n' ' ' < "$duplicates")"
    fi
}

has_import() {
    grep -Fxq "$1" "$2"
}

require_import() {
    local module=$1 root_name=$2 imports=$3
    has_import "$module" "$imports" || fail "$module is not directly imported by $root_name"
}

forbid_import() {
    local module=$1 root_name=$2 imports=$3
    if has_import "$module" "$imports"; then
        fail "$module is assigned to invalid root $root_name"
    fi
}

# Source is scanned lexically so tests behind platform or build-option
# conditionals remain assigned even when they are inactive on this host.
# These three files are root scaffolds, not modules that can import themselves.
while IFS= read -r -d '' file; do
    rel=${file#"$src/"}
    case "$rel" in
        tests.zig|tests_core.zig|webengine.zig) continue ;;
    esac
    if grep -Eq '^[[:space:]]*test([[:space:]]+"|[[:space:]]*\{)' "$file"; then
        printf '%s\n' "$rel"
    fi
done < <(find "$src" -type f -name '*.zig' -print0) | LC_ALL=C sort > "$work/modules"

write_imports "$src/tests.zig" "$work/full"
write_imports "$src/tests_core.zig" "$work/core"
write_imports "$src/webengine.zig" "$work/web"

core_count=0
gui_count=0
cef_count=0
while IFS= read -r module; do
    case "$module" in
        # CEF types are legal only in the opt-in browser-helper test root.
        web/cefhost.zig)
            class=cef
            ;;
        # Deliberate GTK-free model/data exceptions under ui/.
        ui/tabforest.zig|ui/debounce.zig|ui/commandcat.zig|ui/panel/canary.zig|ui/panel/doc.zig|ui/panel/assets.zig|ui/panel/events.zig)
            class=core
            ;;
        # Toolkit/render modules and the few GUI-dependency outliers outside
        # those trees belong only to the full root.
        ui/*|render/*|a11y/nsax.zig|a11y/view.zig|audio_sink.zig|doctor.zig|filebrowser/transfers.zig|ipc/appdrive.zig|ipc/mcp.zig|ipc/mcp_app.zig|ipc/mcp_term.zig|ipc/mcp_web.zig|remote_window.zig|terminal.zig|util/gifrec.zig|wlapp.zig)
            class=gui
            ;;
        *)
            class=core
            ;;
    esac

    case "$class" in
        core)
            require_import "$module" src/tests.zig "$work/full"
            require_import "$module" src/tests_core.zig "$work/core"
            forbid_import "$module" test-web "$work/web"
            core_count=$((core_count + 1))
            ;;
        gui)
            require_import "$module" src/tests.zig "$work/full"
            forbid_import "$module" src/tests_core.zig "$work/core"
            forbid_import "$module" test-web "$work/web"
            gui_count=$((gui_count + 1))
            ;;
        cef)
            require_import "$module" test-web "$work/web"
            forbid_import "$module" src/tests.zig "$work/full"
            forbid_import "$module" src/tests_core.zig "$work/core"
            cef_count=$((cef_count + 1))
            ;;
    esac
done < "$work/modules"

if [[ $cef_count -ne 1 ]]; then
    fail "expected exactly one explicitly classified CEF test module, found $cef_count"
fi

total=$((core_count + gui_count + cef_count))
printf 'PASS: %d test-bearing modules: %d core, %d GUI/render, %d CEF-only\n' \
    "$total" "$core_count" "$gui_count" "$cef_count"
