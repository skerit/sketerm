# sketerm shell integration for fish — source from
# ~/.config/fish/conf.d/sketerm.fish or your config.fish:
#
#   source /path/to/sketerm/data/sketerm-shell-integration.fish
#
# Adds:
#   - OSC 7 cwd reporting (sketerm uses this for layout save +
#     new-tab / split cwd inheritance)
#   - OSC 133 prompt + command marks (Ctrl+Shift+Up/Down nav)
#   - sketerm_copy helper for OSC 52 clipboard set
#
# Skips silently when not running under sketerm.

if test "$TERM_PROGRAM" != "sketerm"
    exit 0
end

# Idempotent: auto-injection + a manual `source` must not double the
# hooks (every prompt would emit two sets of OSC marks).
if set -q _SKETERM_INTEGRATED
    exit 0
end
set -g _SKETERM_INTEGRATED 1

# fish ≥ 4.0 emits OSC 7 cwd and OSC 133 prompt/command marks
# natively — our hooks would double every mark (and the duplicate
# 133;D records each command zone twice). Only register them on
# older fish. NOTE on quoting: inside fish single quotes `\\` is an
# ESCAPED BACKSLASH, so '\e\\' reaches printf as `\e\` — terminate
# OSC with BEL (\a) instead of ST to stay out of that trap.
if not string match -rq '^[4-9]' -- $FISH_VERSION
    # ── OSC 7 cwd ──────────────────────────────────────────────
    function _sketerm_emit_cwd --on-variable PWD
        set -l hn (string lower (hostname 2>/dev/null; or echo localhost))
        set -l cwd (string replace -ar '%' '%25' -- $PWD | string replace -ar ' ' '%20')
        printf '\e]7;file://%s%s\a' $hn $cwd
    end

    # Initial emission for a fresh shell.
    _sketerm_emit_cwd

    # ── OSC 133 marks ──────────────────────────────────────────
    function _sketerm_emit_133a --on-event fish_prompt
        set -l rc $status
        printf '\e]133;D;%d\a\e]133;A\a' $rc
    end

    function _sketerm_emit_133c --on-event fish_preexec
        printf '\e]133;C\a'
    end
end

# ── OSC 52 copy ────────────────────────────────────────────────
function sketerm_copy
    set -l data
    if test (count $argv) -eq 0
        set data (cat)
    else
        set data $argv
    end
    set -l b64 (printf '%s' $data | base64 | tr -d '\n')
    printf '\e]52;c;%s\a' $b64
end
