# sketerm bash bootstrap shim (auto shell-integration).
#
# sketerm spawns interactive bash with `--rcfile <this file>`, which
# replaces BOTH the system bashrc and the user's ~/.bashrc — so first
# source what bash would have read on its own, then load the
# integration script. Login shells never read an rcfile, so this shim
# only ever runs for the interactive non-login case it targets.

[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"

if [ -n "$SKETERM_SHELL_INTEGRATION" ] && [ -r "$SKETERM_SHELL_INTEGRATION" ]; then
    . "$SKETERM_SHELL_INTEGRATION"
    unset SKETERM_SHELL_INTEGRATION
fi
