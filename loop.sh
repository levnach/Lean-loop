#!/usr/bin/env bash
# Lean certificate improvement loop.
#
# Each iteration: rebase the fork's master onto upstream master -> build -> implementer agent
# -> reviewer agent -> integrator agent -> pull request on the fork -> wait for CI (with CI-fixer
# rounds) -> squash-merge into the fork's master -> reporter agent -> publish HTML report on
# GitHub Pages and link it from the PR.
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
mkdir -p "$STATE_DIR" "$LOOP_DIR/logs"

ITERATIONS=1
START=""
SKIP_BUILD=0
RESUME=0
while (( $# )); do
    case "$1" in
        -n|--iterations) ITERATIONS="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --resume) RESUME=1; shift ;;   # first iteration: branch and PR text already exist; start at the push
        -h|--help)
            sed -n '2,8p' "$0"; echo
            echo "usage: $0 [-n ITERATIONS] [--start K] [--skip-build] [--resume]"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

preflight() {
    local tool
    for tool in gh jq cmake ninja python3 curl timeout "$CLAUDE_BIN"; do
        command -v "$tool" >/dev/null || die "missing tool: $tool"
    done
    command -v elan >/dev/null || [[ -x "$HOME/.elan/bin/elan" ]] || die "elan (Lean toolchain manager) not found"
    [[ -d "$REPO_DIR/.git" ]] || die "clone the fork into $REPO_DIR first"
    [[ "$(repo_git remote get-url --push upstream)" == "DISABLED" ]] || die "upstream remote must have pushing disabled"
    [[ -d "$Z3TEST_DIR/.git" ]] || die "clone z3test into $Z3TEST_DIR first"
    local login; login=$(gh api user -q .login)
    [[ "$FORK" == "$login/"* ]] || die "gh is logged in as $login, but the fork is $FORK"
}

fail_iteration() {
    log "ITERATION $ITER FAILED: $*"
    printf '%s\n' "$*" > "$ITER_DIR/FAILED.md"
    printf '| %s | %s | failed | %s | | |\n' "$ITER" "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$STATE_DIR/HISTORY.md"
    return 1
}

run_iteration() {
    ITER="$1"
    ITER_ID=$(printf 'iter-%03d' "$ITER")
    ITER_DIR="$STATE_DIR/$ITER_ID"
    ITER_LOG="$ITER_DIR/iteration.log"
    BRANCH="$BRANCH_PREFIX-$ITER"
    mkdir -p "$ITER_DIR"
    export ITER ITER_ID ITER_DIR BRANCH
    log "=== iteration $ITER: branch $BRANCH ==="

    if (( RESUME )) && [[ "$ITER" == "$START" ]]; then
        # Resume an iteration whose agents finished but whose push or PR failed.
        [[ -s "$ITER_DIR/PR_TITLE.txt" && -s "$ITER_DIR/PR_BODY.md" ]] || die "cannot resume iteration $ITER: no PR title/body in $ITER_DIR"
        repo_git checkout -q "$BRANCH"
        [[ -z "$(repo_git status --porcelain)" ]] || die "cannot resume iteration $ITER: $REPO_DIR has uncommitted changes"
        log "resuming iteration $ITER at the push step: $(repo_git rev-list --count "$BASE_BRANCH..HEAD") commit(s) on $BRANCH"
    else
    sync_fork_master
    git -C "$Z3TEST_DIR" pull -q --ff-only || log "warning: z3test update failed"
    (( SKIP_BUILD )) || build_z3

    repo_git checkout -q -B "$BRANCH" "$BASE_BRANCH"
    BASE_SHA=$(repo_git rev-parse HEAD)
    PREVIOUS_SUMMARIES=$(ls "$STATE_DIR"/iter-*/CHANGE_SUMMARY.md 2>/dev/null | grep -v "/$ITER_ID/" | tr '\n' ' ' || true)
    PREVIOUS_SUMMARIES=${PREVIOUS_SUMMARIES:-"(none; this is the first iteration)"}
    RETRY_NOTE=""
    export BASE_SHA PREVIOUS_SUMMARIES RETRY_NOTE

    # 1. Implement.
    run_agent implementer || log "implementer exited with an error; checking what it produced"
    commit_leftovers implementer
    if [[ "$(repo_git rev-parse HEAD)" == "$BASE_SHA" || ! -s "$ITER_DIR/CHANGE_SUMMARY.md" ]]; then
        log "implementer produced no commits or no summary; retrying once"
        RETRY_NOTE="NOTE: a previous attempt of this iteration ended without commits or without CHANGE_SUMMARY.md (its transcript is $ITER_DIR/implementer.attempt1.stream.log). Pick something you can finish, and make sure to commit and to write the summary."
        export RETRY_NOTE
        mv "$ITER_DIR/implementer.stream.log" "$ITER_DIR/implementer.attempt1.stream.log" 2>/dev/null || true
        run_agent implementer || true
        commit_leftovers implementer
        [[ "$(repo_git rev-parse HEAD)" != "$BASE_SHA" && -s "$ITER_DIR/CHANGE_SUMMARY.md" ]] \
            || { fail_iteration "implementer produced nothing twice"; return 1; }
    fi
    log "change: $(repo_git rev-list --count "$BASE_SHA..HEAD") commit(s), $(repo_git diff --shortstat "$BASE_SHA" HEAD)"

    # 2. Review (read-only; anything it changes is reverted).
    local pre_review; pre_review=$(repo_git rev-parse HEAD)
    run_agent reviewer || log "reviewer exited with an error"
    if [[ "$(repo_git rev-parse HEAD)" != "$pre_review" || -n "$(repo_git status --porcelain)" ]]; then
        log "warning: reviewer modified the repository; reverting"
        repo_git reset -q --hard "$pre_review"
    fi
    if ! grep -q '^VERDICT:' "$ITER_DIR/REVIEW.md" 2>/dev/null; then
        log "warning: reviewer wrote no verdict; recording that for the integrator"
        printf 'VERDICT: REQUEST_CHANGES\n\n## Summary\nThe reviewer produced no usable review file; its final message follows.\n\n%s\n' \
            "$(cat "$ITER_DIR/reviewer.result.md" 2>/dev/null)" > "$ITER_DIR/REVIEW.md"
    fi
    log "review: $(head -n 1 "$ITER_DIR/REVIEW.md")"

    # 3. Integrate: resolve review findings, prepare PR text.
    run_agent integrator || log "integrator exited with an error"
    commit_leftovers integrator
    if [[ -f "$ITER_DIR/ABORT.md" ]]; then
        fail_iteration "integrator aborted: $(head -n 3 "$ITER_DIR/ABORT.md" | tr '\n' ' ')"; return 1
    fi
    [[ -s "$ITER_DIR/PR_TITLE.txt" && -s "$ITER_DIR/PR_BODY.md" ]] || { fail_iteration "integrator wrote no PR title/body"; return 1; }
    fi  # resume
    PR_TITLE=$(head -n 1 "$ITER_DIR/PR_TITLE.txt")

    # 4. Pull request on the fork (driver only). Note: `set -e` is off inside this function
    # (it is called with `||`), so every remote step checks its own result.
    local try
    for try in 1 2 3; do
        repo_git push -q -u origin "$BRANCH" --force-with-lease && break
        log "push of $BRANCH failed (attempt $try)"; (( try < 3 )) && sleep 30
    done
    [[ "$(repo_git rev-parse HEAD)" == "$(repo_git ls-remote origin "refs/heads/$BRANCH" | cut -f1)" ]] \
        || { fail_iteration "could not push $BRANCH to the fork"; return 1; }
    PR_URL=$(ghf pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$PR_TITLE" --body-file "$ITER_DIR/PR_BODY.md") || PR_URL=""
    PR_NUMBER=${PR_URL##*/}
    [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { fail_iteration "could not open the PR for $BRANCH (branch pushed, left for a human)"; return 1; }
    export PR_URL PR_NUMBER PR_TITLE
    ghf pr view "$PR_NUMBER" --json number,url,title,headRefOid,createdAt > "$ITER_DIR/pr.json"
    log "opened PR #$PR_NUMBER: $PR_URL"

    # 5. Gate: the local gate for documentation/Python/Lean-only changes, otherwise GitHub CI
    # with bounded fix rounds.
    local attempt=0 unrelated=0 rc outcome gate="github"
    if local_gate_applies; then
        gate="local"
        log "change touches only local-gate paths; running the local gate instead of waiting for GitHub CI"
        if ! run_local_gate; then
            ghf pr comment "$PR_NUMBER" --body-file "$ITER_DIR/LOCAL_GATE.md" >/dev/null || true
            fail_iteration "local gate failed for PR #$PR_NUMBER (see $ITER_DIR/local-gate.log); PR left open"; return 1
        fi
        log "local gate passed for PR #$PR_NUMBER (log: $ITER_DIR/local-gate.log)"
        ghf pr comment "$PR_NUMBER" --body-file "$ITER_DIR/LOCAL_GATE.md" >/dev/null || true
    else
    while :; do
        rc=0
        wait_for_ci "$PR_NUMBER" "$ITER_DIR/ci-$attempt.json" || rc=$?
        (( rc == 0 )) && break
        (( rc == 2 )) && { fail_iteration "CI did not finish within $CI_TIMEOUT_MIN minutes for PR #$PR_NUMBER"; return 1; }
        attempt=$((attempt + 1))
        (( attempt > MAX_CI_FIX_ATTEMPTS )) && { fail_iteration "CI still failing after $MAX_CI_FIX_ATTEMPTS fix attempts; PR #$PR_NUMBER left open"; return 1; }
        collect_ci_failures "$ITER_DIR/ci-$((attempt - 1)).json" "$ITER_DIR/ci-failures-$attempt.txt"
        CI_ATTEMPT=$attempt CI_STATUS_FILE="$ITER_DIR/ci-$((attempt - 1)).json" CI_FAILURES_FILE="$ITER_DIR/ci-failures-$attempt.txt"
        export CI_ATTEMPT CI_STATUS_FILE CI_FAILURES_FILE
        run_agent ci_fixer || log "ci_fixer exited with an error"
        commit_leftovers ci_fixer
        outcome=$(grep -m1 '^OUTCOME:' "$ITER_DIR/CI_FIX_$attempt.md" 2>/dev/null | awk '{print $2}' || true)
        log "CI fix attempt $attempt: ${outcome:-no outcome recorded}"
        ghf pr edit "$PR_NUMBER" --body-file "$ITER_DIR/PR_BODY.md" >/dev/null || true
        case "$outcome" in
            FIXED) repo_git push -q origin "$BRANCH" --force-with-lease ;;
            UNRELATED) unrelated=1; break ;;
            *) fail_iteration "CI fixer gave up on PR #$PR_NUMBER (left open for a human)"; return 1 ;;
        esac
    done
    fi  # gate

    # 6. Merge (driver only).
    if (( unrelated )); then
        ghf pr comment "$PR_NUMBER" --body "$(printf 'Merging with failing checks that the CI fixer judged unrelated to this change; evidence in the PR description section "CI fix %s".\n' "$attempt")" >/dev/null
    fi
    ghf pr merge "$PR_NUMBER" --squash --delete-branch --subject "$PR_TITLE (#$PR_NUMBER)" --body-file "$ITER_DIR/PR_BODY.md" \
        || { fail_iteration "merge of PR #$PR_NUMBER failed"; return 1; }
    sleep 5
    MERGE_SHA=$(ghf pr view "$PR_NUMBER" --json mergeCommit -q .mergeCommit.oid)
    MERGE_DATE=$(ghf pr view "$PR_NUMBER" --json mergedAt -q .mergedAt)
    export MERGE_SHA MERGE_DATE
    repo_git fetch -q origin "$BASE_BRANCH"
    repo_git checkout -q -f "$BASE_BRANCH"
    repo_git reset -q --hard "origin/$BASE_BRANCH"
    log "merged PR #$PR_NUMBER as $MERGE_SHA"

    # 7. Report page.
    REPORT_URL="$PAGES_URL/reports/pr-$PR_NUMBER.html"
    export REPORT_URL
    run_agent reporter || log "reporter exited with an error"
    repo_git reset -q --hard "origin/$BASE_BRANCH"
    if [[ ! -s "$ITER_DIR/report.html" || ! -s "$ITER_DIR/report-meta.json" ]] || ! jq -e . "$ITER_DIR/report-meta.json" >/dev/null 2>&1; then
        log "warning: reporter produced no valid page; using the fallback report"
        python3 "$LOOP_DIR/tools/fallback_report.py" "$ITER_DIR"
    fi
    publish_report "$PR_NUMBER"

    printf '| %s | %s | [#%s](%s) %s | %s | %s | %s |\n' \
        "$ITER" "$(date '+%Y-%m-%d %H:%M')" "$PR_NUMBER" "$PR_URL" "$PR_TITLE" "$MERGE_SHA" \
        "$([[ $gate == local ]] && echo "local gate" || echo "fix rounds: $attempt")" "$REPORT_URL" >> "$STATE_DIR/HISTORY.md"
    log "=== iteration $ITER done: PR #$PR_NUMBER merged, report $REPORT_URL ==="
}

main() {
    preflight
    ITER_DIR="$STATE_DIR/setup"; mkdir -p "$ITER_DIR"; ITER_LOG="$ITER_DIR/setup.log"
    ensure_pages
    [[ -f "$STATE_DIR/HISTORY.md" ]] || printf '# Loop history\n\n| iteration | finished | PR | merge | CI | report |\n| --- | --- | --- | --- | --- | --- |\n' > "$STATE_DIR/HISTORY.md"
    if [[ -z "$START" ]]; then
        local last
        last=$(ls -d "$STATE_DIR"/iter-* 2>/dev/null | sed 's/.*iter-0*//' | sort -n | tail -n 1 || true)
        START=$(( ${last:-0} + 1 ))
    fi
    local i
    for (( i = START; i < START + ITERATIONS; i++ )); do
        run_iteration "$i" || die "stopping after a failed iteration $i"
    done
    log "all $ITERATIONS iteration(s) completed; history in $STATE_DIR/HISTORY.md"
}

main "$@"
