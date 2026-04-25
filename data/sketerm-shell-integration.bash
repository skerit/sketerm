#!/usr/bin/env bash
# sketerm shell integration — source this from your .bashrc.
#
#   source /path/to/sketerm/data/sketerm-shell-integration.bash
#
# Adds:
#   - OSC 7 cwd reporting (sketerm uses this for layout save)
#   - Optional OSC 52 clipboard copy via $sketerm_copy
#
# Skips silently when not running under sketerm.

if [[ "$TERM_PROGRAM" != "sketerm" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── OSC 7 cwd reporting ─────────────────────────────────────────
# Emits ESC ] 7 ; file://hostname/cwd ESC \ after every prompt.
# sketerm captures this and stores it on the Terminal so layout
# save can write the right cwd.

_sketerm_emit_cwd() {
    local hostname="${HOSTNAME:-localhost}"
    local cwd="${PWD//%/%25}"
    cwd="${cwd// /%20}"
    printf '\033]7;file://%s%s\033\\' "$hostname" "$cwd"
}

# Append to PROMPT_COMMAND without clobbering existing entries.
case "$PROMPT_COMMAND" in
    *_sketerm_emit_cwd*) ;;
    "") PROMPT_COMMAND='_sketerm_emit_cwd' ;;
    *)  PROMPT_COMMAND="${PROMPT_COMMAND%;};_sketerm_emit_cwd" ;;
esac

# ── OSC 52 copy helper ──────────────────────────────────────────
# Pipe text into `sketerm_copy` to put it on the local clipboard
# even over SSH:
#
#   echo hello | sketerm_copy

sketerm_copy() {
    local data
    if [[ $# -eq 0 ]]; then
        data="$(cat)"
    else
        data="$*"
    fi
    local b64
    b64="$(printf '%s' "$data" | base64 | tr -d '\n')"
    printf '\033]52;c;%s\007' "$b64"
}

# ── Bracketed paste hint ────────────────────────────────────────
# bash readline ≥ 7 already enables DECSET 2004; just confirm it.
bind 'set enable-bracketed-paste on' 2>/dev/null
