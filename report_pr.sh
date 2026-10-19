#!/usr/bin/env bash
# Produce and publish the HTML report for an already merged loop PR.
#
#   ./report_pr.sh ITERATION PR_NUMBER
#
# Used when a PR was merged outside the driver (for example by hand before CI finished),
# so the driver never reached its reporting step. Runs the reporter agent against the
# iteration's artifacts, publishes the page to gh-pages, and comments the link on the PR.
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
REPORT_URL="$PAGES_URL/reports/pr-$PR_NUMBER.html"
BRANCH="$BRANCH_PREFIX-$ITER"
export ITER ITER_ID ITER_DIR BRANCH PR_URL PR_NUMBER PR_TITLE MERGE_SHA MERGE_DATE REPORT_URL

log "=== report for iteration $ITER, PR #$PR_NUMBER (merged as $MERGE_SHA) ==="
ghf pr view "$PR_NUMBER" --json number,url,title,headRefOid,createdAt > "$ITER_DIR/pr.json"
ghf pr checks "$PR_NUMBER" --json name,state,bucket,workflow,link,startedAt,completedAt > "$ITER_DIR/ci-final.json.raw" 2>/dev/null || true
python3 "$LOOP_DIR/tools/ci_status.py" "$ITER_DIR/ci-final.json.raw" "$GATING_WORKFLOWS" 999 0 "$ITER_DIR/ci-final.json" >/dev/null || true

repo_git fetch -q origin "$BASE_BRANCH"
repo_git checkout -q -f "$BASE_BRANCH"
repo_git reset -q --hard "origin/$BASE_BRANCH"
ensure_pages
run_agent reporter || log "reporter exited with an error"
repo_git reset -q --hard "origin/$BASE_BRANCH"
if [[ ! -s "$ITER_DIR/report.html" || ! -s "$ITER_DIR/report-meta.json" ]] || ! jq -e . "$ITER_DIR/report-meta.json" >/dev/null 2>&1; then
    log "warning: reporter produced no valid page; using the fallback report"
    python3 "$LOOP_DIR/tools/fallback_report.py" "$ITER_DIR"
fi
publish_report "$PR_NUMBER"
printf '| %s | %s | [#%s](%s) %s | %s | merged by hand before CI finished | %s |\n' \
    "$ITER" "$(date '+%Y-%m-%d %H:%M')" "$PR_NUMBER" "$PR_URL" "$PR_TITLE" "$MERGE_SHA" "$REPORT_URL" >> "$STATE_DIR/HISTORY.md"
log "=== report published: $REPORT_URL ==="
