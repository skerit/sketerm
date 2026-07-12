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

# Idempotent: a double `source` must not double the hooks.
if [[ -n "$_SKETERM_INTEGRATED" ]]; then
    return 0 2>/dev/null || exit 0
fi
_SKETERM_INTEGRATED=1

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

# ── OSC 133 prompt marks ────────────────────────────────────────
# Tags each prompt so sketerm's Ctrl+Shift+Up/Down can jump between
# them. FinalTerm spec:
#   A = start of prompt          (PS1 prefix)
#   B = end of prompt / input    (PS1 suffix)
#   C = start of command output  (PS0, post-Enter pre-exec)
#   D = end of output            (PROMPT_COMMAND, before next prompt)
#
# Wraps PS1 with A / B markers if not already wrapped.
#
# C comes from PS0 (bash >= 4.4), NOT a DEBUG trap: bash expands PS0
# exactly once per interactive command, after the accept-line newline
# and before execution. A DEBUG trap also fires for the commands
# INSIDE the (possibly distro-provided) PROMPT_COMMAND, emitting a
# spurious C at the next-prompt row — the zone then swallowed the
# prompt and command echo. Older bash: prompt marks only, no zones.

if [[ -z "${SKETERM_OSC133_INSTALLED:-}" && "$PS1" != *$'\001\033]133;A\033\\\002'* ]]; then
    PS1=$'\001\033]133;A\033\\\002'"$PS1"$'\001\033]133;B\033\\\002'
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        PS0=$'\033]133;C\033\\'"${PS0:-}"
    fi
    SKETERM_OSC133_INSTALLED=1
fi

_sketerm_emit_133d() {
    local rc=$?
    # A D with no C open is dropped by the terminal, so the bare-Enter
    # case (PROMPT_COMMAND reruns, PS0 never expanded) is harmless.
    printf '\033]133;D;%d\033\\' "$rc"
    return $rc
}

# Append to PROMPT_COMMAND without clobbering existing entries.
# Order matters: 133;D first (command finished), then cwd update.
case "$PROMPT_COMMAND" in
    *_sketerm_emit_cwd*) ;;
    "") PROMPT_COMMAND='_sketerm_emit_133d;_sketerm_emit_cwd' ;;
    *)  PROMPT_COMMAND="_sketerm_emit_133d;${PROMPT_COMMAND%;};_sketerm_emit_cwd" ;;
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
