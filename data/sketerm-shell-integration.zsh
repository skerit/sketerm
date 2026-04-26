#!/usr/bin/env zsh
# sketerm shell integration for zsh — source from ~/.zshrc.
#
#   source /path/to/sketerm/data/sketerm-shell-integration.zsh
#
# Adds:
#   - OSC 7 cwd reporting (sketerm uses this for layout save +
#     new-tab / split cwd inheritance)
#   - OSC 133 prompt + command marks (for Ctrl+Shift+Up/Down nav)
#   - sketerm_copy() helper for OSC 52 clipboard set
#
# Skips silently when not running under sketerm.

[[ "$TERM_PROGRAM" != "sketerm" ]] && return 0

# ── OSC 7 cwd reporting ─────────────────────────────────────────
_sketerm_emit_cwd() {
    local hn="${HOST:-${HOSTNAME:-localhost}}"
    local cwd="${PWD//%/%25}"
    cwd="${cwd// /%20}"
    printf '\033]7;file://%s%s\033\\' "$hn" "$cwd"
}

# Hook _sketerm_emit_cwd into chpwd so sketerm sees the new cwd
# immediately (zsh fires chpwd after cd / pushd / popd).
typeset -ag chpwd_functions
chpwd_functions+=(_sketerm_emit_cwd)

# ── OSC 133 marks ───────────────────────────────────────────────
# precmd runs before each prompt; preexec runs just before a
# command begins. Map:
#   A = prompt start          → emit at precmd
#   D = prev command done     → emit at precmd (with $? rc)
#   C = command start         → emit at preexec
# B (end of input) is harder to get exactly right in zsh without
# a custom prompt; we omit it and apps that probe for B fall back.

_sketerm_emit_133a() {
    local rc=$?
    printf '\033]133;D;%d\033\\\033]133;A\033\\' "$rc"
    return $rc
}

_sketerm_emit_133c() {
    printf '\033]133;C\033\\'
}

typeset -ag precmd_functions preexec_functions
precmd_functions+=(_sketerm_emit_133a _sketerm_emit_cwd)
preexec_functions+=(_sketerm_emit_133c)

# Send the initial cwd so a fresh shell reports cwd before its
# first command.
_sketerm_emit_cwd

# ── OSC 52 copy ─────────────────────────────────────────────────
sketerm_copy() {
    local data
    if (( $# == 0 )); then
        data="$(cat)"
    else
        data="$*"
    fi
    local b64
    b64="$(printf '%s' "$data" | base64 | tr -d '\n')"
    printf '\033]52;c;%s\007' "$b64"
}
