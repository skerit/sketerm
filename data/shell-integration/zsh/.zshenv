# sketerm zsh bootstrap shim (auto shell-integration).
#
# sketerm spawns zsh with ZDOTDIR pointing at this directory; zsh
# reads this .zshenv first, we immediately restore the user's real
# ZDOTDIR so every later startup file (.zprofile/.zshrc/.zlogin)
# comes from their own config, then arrange the integration script
# to load right before the first prompt (after .zshrc, so user
# prompt frameworks are already set up).

if [[ -n "$SKETERM_ORIG_ZDOTDIR" ]]; then
    export ZDOTDIR="$SKETERM_ORIG_ZDOTDIR"
    unset SKETERM_ORIG_ZDOTDIR
else
    unset ZDOTDIR
fi

# Chain into the user's real .zshenv, if any.
if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
    builtin source "${ZDOTDIR:-$HOME}/.zshenv"
fi

if [[ -o interactive && -n "$SKETERM_SHELL_INTEGRATION" ]]; then
    _sketerm_load_integration() {
        precmd_functions=(${precmd_functions:#_sketerm_load_integration})
        [[ -r "$SKETERM_SHELL_INTEGRATION" ]] && builtin source "$SKETERM_SHELL_INTEGRATION"
        unset SKETERM_SHELL_INTEGRATION
        unset -f _sketerm_load_integration
    }
    typeset -ga precmd_functions
    precmd_functions+=(_sketerm_load_integration)
fi
