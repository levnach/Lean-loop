#!/usr/bin/env bash
# Run loop iterations one at a time until a merged iteration changes C++ code (src/**),
# then stop so that an upstream pull request can be opened. Also stops on a failed iteration
# or after MAX iterations (safety cap).
set -euo pipefail
LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MAX="${1:-10}"
OUT="$LOOP_DIR/logs/run_until_cpp.log"
say() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$OUT" >&2; }
# Files of the iteration's own squash commit (the tip of the fork's master after the merge).
# The start-of-iteration rebase also pulls in upstream commits, which must not count.
cpp_files() { git -C "$LOOP_DIR/repo" diff-tree --no-commit-id --name-only -r "$2" | grep -E '^src/|\.(cpp|h|hpp|c)$' || true; }
for (( i = 1; i <= MAX; i++ )); do
    git -C "$LOOP_DIR/repo" fetch -q origin master
    before=$(git -C "$LOOP_DIR/repo" rev-parse origin/master)
    say "run $i/$MAX: fork master $before"
    if ! "$LOOP_DIR/loop.sh" -n 1 >> "$LOOP_DIR/logs/run_until_cpp.loop.out" 2>&1; then
        say "STOP: iteration failed (see logs/loop.log)"; exit 1
    fi
    git -C "$LOOP_DIR/repo" fetch -q origin master
    after=$(git -C "$LOOP_DIR/repo" rev-parse origin/master)
    files=$(cpp_files "$before" "$after")
    if [[ -n "$files" ]]; then
        say "STOP: the merged PR commit $after changes C++:"; printf '%s\n' "$files" | tee -a "$OUT" >&2
        printf '%s\n' "$after" > "$LOOP_DIR/state/CPP_STOP_SHA"
        exit 0
    fi
    say "run $i: merged $after, no C++ change; continuing"
done
say "STOP: reached the cap of $MAX iterations without a C++ change"
exit 2
