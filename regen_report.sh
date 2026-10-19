#!/usr/bin/env bash
# Regenerate and republish the HTML report for an already merged and already reported loop PR.
#
#   ./regen_report.sh ITERATION PR_NUMBER
#
# Like report_pr.sh, but for rewriting an existing page: it does not comment on the PR again
# and does not append to state/HISTORY.md. The previous report.html is kept as report.prev.html.
set -euo pipefail

LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=config.env
source "$LOOP_DIR/config.env"
# shellcheck source=lib.sh
source "$LOOP_DIR/lib.sh"

REPO_DIR="$LOOP_DIR/repo"
Z3TEST_DIR="$LOOP_DIR/z3test"
PAGES_DIR="$LOOP_DIR/pages"
STATE_DIR="$LOOP_DIR/state"
BUILD_DIR="$REPO_DIR/build"
AGENT_ALLOWED_TOOLS+=",Bash($BUILD_DIR/z3:*),Bash($BUILD_DIR/test-z3:*),Bash($REPO_DIR/scripts/check_lean.sh:*)"
export LOOP_DIR REPO_DIR Z3TEST_DIR PAGES_DIR STATE_DIR BUILD_DIR BUILD_JOBS FORK UPSTREAM BASE_BRANCH MAX_CI_FIX_ATTEMPTS

[[ $# -eq 2 ]] || { echo "usage: $0 ITERATION PR_NUMBER" >&2; exit 2; }
ITER="$1"; PR_NUMBER="$2"
ITER_ID=$(printf 'iter-%03d' "$ITER")
ITER_DIR="$STATE_DIR/$ITER_ID"
ITER_LOG="$ITER_DIR/iteration.log"
[[ -d "$ITER_DIR" ]] || die "no iteration directory $ITER_DIR"

PR_URL=$(ghf pr view "$PR_NUMBER" --json url -q .url)
PR_TITLE=$(ghf pr view "$PR_NUMBER" --json title -q .title)
MERGE_SHA=$(ghf pr view "$PR_NUMBER" --json mergeCommit -q .mergeCommit.oid)
MERGE_DATE=$(ghf pr view "$PR_NUMBER" --json mergedAt -q .mergedAt)
[[ -n "$MERGE_SHA" && "$MERGE_SHA" != "null" ]] || die "PR #$PR_NUMBER is not merged"
repo_git cat-file -e "$MERGE_SHA^{commit}" 2>/dev/null || repo_git fetch -q origin "$MERGE_SHA" || die "merge commit $MERGE_SHA is not available locally"
REPORT_URL="$PAGES_URL/reports/pr-$PR_NUMBER.html"
BRANCH="$BRANCH_PREFIX-$ITER"
export ITER ITER_ID ITER_DIR BRANCH PR_URL PR_NUMBER PR_TITLE MERGE_SHA MERGE_DATE REPORT_URL

log "=== regenerating report for iteration $ITER, PR #$PR_NUMBER (merged as $MERGE_SHA) ==="
[[ -s "$ITER_DIR/report.html" ]] && cp "$ITER_DIR/report.html" "$ITER_DIR/report.prev.html"
[[ -s "$ITER_DIR/pr.json" ]] || ghf pr view "$PR_NUMBER" --json number,url,title,headRefOid,createdAt > "$ITER_DIR/pr.json"
if ! ls "$ITER_DIR"/ci-*.json >/dev/null 2>&1; then
    ghf pr checks "$PR_NUMBER" --json name,state,bucket,workflow,link,startedAt,completedAt > "$ITER_DIR/ci-final.json.raw" 2>/dev/null || true
    python3 "$LOOP_DIR/tools/ci_status.py" "$ITER_DIR/ci-final.json.raw" "$GATING_WORKFLOWS" 999 0 "$ITER_DIR/ci-final.json" >/dev/null || true
fi

# Work in a detached worktree at the merge commit so that a running loop iteration in
# $REPO_DIR (on its own branch) is not disturbed. The z3 build and bindings stay shared.
WORK_DIR="$LOOP_DIR/work/report-pr-$PR_NUMBER"
repo_git worktree remove --force "$WORK_DIR" 2>/dev/null || true
rm -rf "$WORK_DIR"; mkdir -p "$LOOP_DIR/work"
repo_git worktree add -q --detach "$WORK_DIR" "$MERGE_SHA" || die "cannot create worktree at $MERGE_SHA"
REPO_DIR="$WORK_DIR"
AGENT_ALLOWED_TOOLS+=",Bash($REPO_DIR/scripts/check_lean.sh:*)"
export REPO_DIR
ensure_pages
run_agent reporter || log "reporter exited with an error"
git -C "$WORK_DIR" reset -q --hard "$MERGE_SHA"
if [[ ! -s "$ITER_DIR/report.html" || ! -s "$ITER_DIR/report-meta.json" ]] || ! jq -e . "$ITER_DIR/report-meta.json" >/dev/null 2>&1; then
    die "reporter produced no valid page; the previous page is left in place (see $ITER_DIR/report.prev.html)"
fi

mkdir -p "$PAGES_DIR/reports"
cp "$ITER_DIR/report.html" "$PAGES_DIR/reports/pr-$PR_NUMBER.html"
cp "$ITER_DIR/report-meta.json" "$PAGES_DIR/reports/pr-$PR_NUMBER.json"
python3 "$LOOP_DIR/tools/make_index.py" "$PAGES_DIR"
git -C "$PAGES_DIR" add -A
git -C "$PAGES_DIR" commit -q -m "Regenerate report for PR #$PR_NUMBER" || true
git -C "$PAGES_DIR" push -q origin "$PAGES_BRANCH" || die "pushing the report to $PAGES_BRANCH failed"
git -C "$LOOP_DIR/repo" worktree remove --force "$WORK_DIR" 2>/dev/null || true
log "=== report regenerated and pushed: $REPORT_URL (Pages rebuild may take a few minutes) ==="
