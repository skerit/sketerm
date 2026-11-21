#!/usr/bin/env bash
# Version-skew gate (`zig build test-skew`, a dependency of `test` and
# `test-core`): builds the `sketerm-mux` of every commit in
# skew-baselines.txt once per machine, then runs src/smoke_skew.zig with
# those binaries against this tree's sketerm-mux.
#
# Usage (build.zig passes these): test-skew.sh <zig> <head sketerm-mux> <skew rig>
#
# A baseline is built from a `git archive` of its commit in a temporary
# tree under the cache, with `zig build mux` at its default ReleaseFast
# (LLVM): the profile every shipped daemon was built with, and the only
# step that builds just the daemon at all three original baselines. Only
# the binary is kept, at $XDG_CACHE_HOME/sketerm/skew/<sha>/sketerm-mux,
# placed by rename so two concurrent runs never see a partial file. The
# build runs with GIT_DIR pointing nowhere, so the baseline's build id is
# "unknown" rather than whatever repository the cache dir happens to sit
# in. SKETERM_SKEW_ZIG overrides the compiler for the baselines (they need
# a toolchain their own build.zig accepts).
#
# Not a git checkout of this tree (a release tarball, a fetched Zig
# package): SKIP. Every other failure to produce a baseline FAILS.

set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
root=$(readlink -f "$here/..")
[[ $# -eq 3 ]] || { printf 'usage: %s <zig> <head sketerm-mux> <skew rig>\n' "$0" >&2; exit 2; }
zig=${SKETERM_SKEW_ZIG:-$1}
head_mux=$2
rig=$3

fail() {
    printf 'test-skew: FAIL: %s\n' "$*" >&2
    exit 1
}

if ! command -v git >/dev/null 2>&1; then
    [[ -e $root/.git ]] && fail "$root is a git checkout but git is not installed"
    printf 'test-skew: SKIP: %s is not a git checkout (no git); no baseline can be built\n' "$root"
    exit 0
fi
top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z $top || $(readlink -f "$top") != "$root" ]]; then
    printf 'test-skew: SKIP: %s is not a git checkout; no baseline can be built\n' "$root"
    exit 0
fi

mapfile -t baselines < <(sed -e 's/#.*//' "$here/skew-baselines.txt" | awk 'NF { print $1 }')
[[ ${#baselines[@]} -gt 0 ]] || fail "skew-baselines.txt lists no baseline"
for sha in "${baselines[@]}"; do
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || fail "skew-baselines.txt: '$sha' is not a full commit SHA"
done

cache=${XDG_CACHE_HOME:-$HOME/.cache}/sketerm/skew

# Build one baseline into the cache; prints why on failure.
build_one() {
    local sha=$1
    local dir=$cache/$sha
    [[ -x $dir/sketerm-mux ]] && return 0
    git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null \
        || { printf 'commit %s is not in this clone (shallow clone? fetch it)\n' "$sha"; return 1; }
    mkdir -p "$dir"
    # Leftovers of a run killed mid-build; no build takes two hours.
    find "$dir" -maxdepth 1 -name 'build.*' -mmin +120 -exec rm -rf {} + 2>/dev/null || true
    local work
    work=$(mktemp -d "$dir/build.XXXXXX")
    (
        trap 'rm -rf "$work"' EXIT
        mkdir "$work/src"
        git -C "$root" archive "$sha" | tar -x -C "$work/src"
        local started=$SECONDS
        if ! (cd "$work/src" && GIT_DIR=/nonexistent "$zig" build mux --prefix "$work/out") >"$work/build.log" 2>&1; then
            tail -n 40 "$work/build.log"
            printf 'zig build mux failed at %s\n' "$sha"
            exit 1
        fi
        mv -f "$work/out/bin/sketerm-mux" "$dir/sketerm-mux"
        printf 'test-skew: built baseline %s in %ss\n' "${sha:0:8}" $((SECONDS - started))
    )
}

# Cold builds run in parallel; each reports into its own log.
logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT
pids=()
for sha in "${baselines[@]}"; do
    if [[ -x $cache/$sha/sketerm-mux ]]; then
        pids+=("")
        continue
    fi
    printf 'test-skew: building baseline %s (once per machine)\n' "${sha:0:8}"
    build_one "$sha" >"$logs/$sha" 2>&1 &
    pids+=("$!")
done
failed=0
for i in "${!baselines[@]}"; do
    sha=${baselines[$i]}
    [[ -n ${pids[$i]} ]] || continue
    if wait "${pids[$i]}"; then
        cat "$logs/$sha"
    else
        cat "$logs/$sha" >&2
        printf 'test-skew: FAIL: could not build baseline %s\n' "$sha" >&2
        failed=1
    fi
done
[[ $failed -eq 0 ]] || exit 1

args=()
for sha in "${baselines[@]}"; do
    [[ -x $cache/$sha/sketerm-mux ]] || fail "baseline $sha has no cached binary after its build"
    args+=("$sha" "$cache/$sha/sketerm-mux")
done
rm -rf "$logs"
trap - EXIT
exec "$rig" "$head_mux" "${args[@]}"
