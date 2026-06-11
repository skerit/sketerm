# sketerm fish bootstrap shim (auto shell-integration).
#
# sketerm prepends the fish-xdg directory to XDG_DATA_DIRS when
# spawning fish; fish auto-sources every vendor_conf.d snippet. We
# load the real integration script and immediately strip our entry
# back out of XDG_DATA_DIRS so child processes see a clean value.

if status is-interactive; and test "$TERM_PROGRAM" = sketerm
    if set -q SKETERM_SHELL_INTEGRATION; and test -r "$SKETERM_SHELL_INTEGRATION"
        source "$SKETERM_SHELL_INTEGRATION"
    end
    set -e SKETERM_SHELL_INTEGRATION
end

# Remove the shim dir from XDG_DATA_DIRS regardless of TERM_PROGRAM.
if set -q XDG_DATA_DIRS
    set -l cleaned
    for d in (string split : -- $XDG_DATA_DIRS)
        string match -q '*sketerm*shell-integration/fish-xdg' -- $d; and continue
        set -a cleaned $d
    end
    if test (count $cleaned) -gt 0
        set -gx XDG_DATA_DIRS (string join : -- $cleaned)
    else
        set -e XDG_DATA_DIRS
    end
end
