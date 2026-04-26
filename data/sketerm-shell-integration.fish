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

# ── OSC 7 cwd ──────────────────────────────────────────────────
function _sketerm_emit_cwd --on-variable PWD
    set -l hn (string lower (hostname 2>/dev/null; or echo localhost))
    set -l cwd (string replace -ar '%' '%25' -- $PWD | string replace -ar ' ' '%20')
    printf '\e]7;file://%s%s\e\\' $hn $cwd
end

# Initial emission for a fresh shell.
_sketerm_emit_cwd

# ── OSC 133 marks ──────────────────────────────────────────────
function _sketerm_emit_133a --on-event fish_prompt
    set -l rc $status
    printf '\e]133;D;%d\e\\\e]133;A\e\\' $rc
end

function _sketerm_emit_133c --on-event fish_preexec
    printf '\e]133;C\e\\'
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
