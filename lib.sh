# shellcheck shell=bash
# Helper functions for loop.sh. Requires LOOP_DIR and config.env to be loaded.

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line" >> "$LOOP_DIR/logs/loop.log"
    [[ -n "${ITER_LOG:-}" ]] && printf '%s\n' "$line" >> "$ITER_LOG"
    printf '%s\n' "$line" >&2
}

die() { log "FATAL: $*"; exit 1; }

# gh against the fork, run outside the clone so that gh never touches local branches.
ghf() { (cd "$LOOP_DIR" && gh -R "$FORK" "$@"); }
ghp() { (cd "$LOOP_DIR" && gh -R "${PR_REPO:-$FORK}" "$@"); }

repo_git() { git -C "$REPO_DIR" "$@"; }

render_prompt() {  # role, destination
    python3 "$LOOP_DIR/tools/render_prompt.py" "$LOOP_DIR/prompts/$1.md" "$2"
}

# run_agent ROLE: renders prompts/ROLE.md and runs a headless claude session in the clone.
# The agent gets only the tools listed in AGENT_ALLOWED_TOOLS (no push, no PR, no merge);
# the driver performs every remote operation itself.
# Writes ITER_DIR/ROLE.stream.log (events), ROLE.json (final result), ROLE.result.md.
run_agent() {
    local role="$1"
    [[ "$role" != reporter ]] || report_context
    local prompt="$ITER_DIR/$role.prompt.md"
    local stream="$ITER_DIR/$role.stream.log"
    local result="$ITER_DIR/$role.json"
    render_prompt "$role" "$prompt" || die "cannot render prompt for $role"
    local args=(-p --permission-mode acceptEdits --allowedTools "$AGENT_ALLOWED_TOOLS"
                --output-format stream-json --verbose --max-turns "$AGENT_MAX_TURNS"
                --add-dir "$STATE_DIR" --add-dir "$Z3TEST_DIR")
    [[ -n "$CLAUDE_MODEL" ]] && args+=(--model "$CLAUDE_MODEL")
    log "agent[$role]: start (events: $stream)"
    local start=$SECONDS rc=0
    (cd "$REPO_DIR" && env -u CLAUDECODE \
        PYTHONPATH="$BUILD_DIR/python" Z3_EXE="$BUILD_DIR/z3" Z3_SOURCE="$REPO_DIR" GIT_EDITOR=true \
        timeout -k 60 "$((AGENT_TIMEOUT_MIN * 60))" \
        "$CLAUDE_BIN" "${args[@]}" < "$prompt" > "$stream" 2> "$ITER_DIR/$role.stderr.log") || rc=$?
    jq -c 'select(.type == "result")' "$stream" 2>/dev/null | tail -n 1 > "$result" || true
    if [[ -s "$result" ]]; then
        jq -r '.result // ""' "$result" > "$ITER_DIR/$role.result.md"
        log "agent[$role]: done rc=$rc in $(( (SECONDS - start) / 60 ))m, turns=$(jq -r '.num_turns // "?"' "$result"), cost=\$$(jq -r '.total_cost_usd // 0 | . * 100 | round / 100' "$result"), subtype=$(jq -r '.subtype // "?"' "$result")"
    else
        log "agent[$role]: done rc=$rc in $(( (SECONDS - start) / 60 ))m, no result event (see $ITER_DIR/$role.stderr.log)"
    fi
    return $rc
}

report_context() {
    PR_REPO="${PR_REPO:-$FORK}"
    PR_STATE="OPEN"
    [[ -z "${MERGE_SHA:-}" ]] || PR_STATE="MERGED"
    [[ "${PR_NUMBER:-0}" != 0 ]] || PR_STATE="PREPARING"
    CHANGE_SHA="${MERGE_SHA:-$(repo_git rev-parse HEAD)}"
    PR_DATE="${MERGE_DATE:-}"
    if [[ -z "$PR_DATE" && -s "$ITER_DIR/pr.json" ]]; then
        PR_DATE=$(jq -r '.createdAt // ""' "$ITER_DIR/pr.json") || return 1
    fi
    export PR_REPO PR_STATE CHANGE_SHA PR_DATE
}

valid_report() {
    [[ -s "$ITER_DIR/report.html" && -s "$ITER_DIR/report-meta.json" ]] &&
        jq -e --argjson number "$PR_NUMBER" --arg state "$PR_STATE" --arg sha "$CHANGE_SHA" \
            '.number == $number and .state == $state and .head_sha == $sha' \
            "$ITER_DIR/report-meta.json" >/dev/null 2>&1
}

generate_report() {
    report_context || return 1
    local before; before=$(repo_git rev-parse HEAD) || return 1
    run_agent reporter || log "reporter exited with an error; checking its output"
    if [[ "$(repo_git rev-parse HEAD)" != "$before" || -n "$(repo_git status --porcelain)" ]]; then
        log "reporter modified the repository; stopping without discarding its changes"
        return 1
    fi
    if ! valid_report; then
        log "reporter produced no current report; rendering the HTML PR description"
        python3 "$LOOP_DIR/tools/fallback_report.py" "$ITER_DIR" || return 1
    fi
    valid_report
}

open_pr_with_report() {
    PR_REPO="${1:-$FORK}"
    local head="${2:-$BRANCH}" existing
    PR_NUMBER=0 PR_URL="" REPORT_URL="" MERGE_SHA="" MERGE_DATE=""
    export PR_REPO PR_NUMBER PR_URL REPORT_URL MERGE_SHA MERGE_DATE PR_TITLE
    report_context || return 1
    existing=$(ghp pr list --head "${head#*:}" --author "${FORK%%/*}" --state open \
        --json number --jq '.[0].number // empty') || return 1
    if [[ -n "$existing" ]]; then
        PR_NUMBER="$existing"
    else
        python3 "$LOOP_DIR/tools/fallback_report.py" "$ITER_DIR" || return 1
        PR_URL=$(ghp pr create --draft --base "$BASE_BRANCH" --head "$head" \
            --title "$PR_TITLE" --body-file "$ITER_DIR/PR_BODY.md") || return 1
        PR_NUMBER=${PR_URL##*/}
    fi
    [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || return 1
    ghp pr view "$PR_NUMBER" --json number,url,title,headRefOid,createdAt,state,isDraft > "$ITER_DIR/pr.json" || return 1
    PR_URL=$(jq -r .url "$ITER_DIR/pr.json") || return 1
    local path="reports/pr-$PR_NUMBER.html"
    [[ "$PR_REPO" == "$FORK" ]] || path="reports/upstream/pr-$PR_NUMBER.html"
    REPORT_URL="$PAGES_URL/$path"
    export PR_URL PR_NUMBER REPORT_URL
    log "preparing HTML report for draft PR $PR_REPO#$PR_NUMBER"
    generate_report || return 1
    publish_report "$PR_NUMBER" || return 1
    if jq -e '.isDraft' "$ITER_DIR/pr.json" >/dev/null; then
        ghp pr ready "$PR_NUMBER" >/dev/null || return 1
    fi
    ghp pr view "$PR_NUMBER" --json number,url,title,headRefOid,createdAt,state,isDraft > "$ITER_DIR/pr.json" || return 1
    log "opened PR with HTML report: $PR_URL ($REPORT_URL)"
}

# Commit anything an agent left uncommitted so that the branch carries the complete change.
commit_leftovers() {  # who
    if [[ -n "$(repo_git status --porcelain)" ]]; then
        log "warning: $1 left uncommitted changes; committing them"
        repo_git status --porcelain >> "$ITER_LOG"
        repo_git add -A
        repo_git commit -q -m "Loop driver: include changes left uncommitted by the $1" || true
    fi
}

# Rebase the fork's master onto upstream master and force-push it.
sync_fork_master() {
    repo_git rebase --abort >/dev/null 2>&1 || true
    repo_git checkout -q -f "$BASE_BRANCH" 2>/dev/null || repo_git checkout -q -b "$BASE_BRANCH" "origin/$BASE_BRANCH"
    repo_git fetch -q origin "$BASE_BRANCH"
    repo_git reset -q --hard "origin/$BASE_BRANCH"
    repo_git fetch -q upstream "$BASE_BRANCH"
    local before; before=$(repo_git rev-parse HEAD)
    if ! repo_git rebase "upstream/$BASE_BRANCH" > "$ITER_DIR/rebase.log" 2>&1; then
        log "rebase onto upstream/$BASE_BRANCH has conflicts; running the rebaser agent"
        run_agent rebaser || true
        if [[ -d "$REPO_DIR/.git/rebase-merge" || -d "$REPO_DIR/.git/rebase-apply" ]]; then
            repo_git rebase --abort || true
            die "rebase could not be resolved; see $ITER_DIR/rebase.log and rebaser.stream.log"
        fi
    fi
    local after; after=$(repo_git rev-parse HEAD)
    if [[ "$after" != "$before" ]]; then
        repo_git push -q --force-with-lease origin "$BASE_BRANCH" || die "pushing rebased $BASE_BRANCH to the fork failed"
    fi
    log "fork $BASE_BRANCH = $(repo_git rev-parse --short HEAD): upstream $(repo_git rev-parse --short "upstream/$BASE_BRANCH") + $(repo_git rev-list --count "upstream/$BASE_BRANCH..HEAD") loop commit(s)"
}

build_z3() {
    if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
        log "configuring z3 build in $BUILD_DIR"
        cmake -G Ninja -S "$REPO_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release \
            -DZ3_BUILD_PYTHON_BINDINGS=ON > "$ITER_DIR/configure.log" 2>&1 || die "cmake configure failed; see $ITER_DIR/configure.log"
    fi
    log "building z3 (log: $ITER_DIR/build.log)"
    local start=$SECONDS
    cmake --build "$BUILD_DIR" --parallel "$BUILD_JOBS" > "$ITER_DIR/build.log" 2>&1 || die "z3 build failed; see $ITER_DIR/build.log"
    log "z3 built in $(( (SECONDS - start) / 60 ))m"
    log "building the Lean project (log: $ITER_DIR/lean-build.log)"
    (cd "$REPO_DIR" && ./scripts/check_lean.sh > "$ITER_DIR/lean-build.log" 2>&1) || die "Lean project build failed; see $ITER_DIR/lean-build.log"
}

# local_gate_applies: succeeds when every file the branch changes matches LOCAL_GATE_PATHS.
local_gate_applies() {
    local base files
    base=$(repo_git merge-base "origin/$BASE_BRANCH" HEAD) || return 1
    files=$(repo_git diff --name-only "$base" HEAD)
    [[ -n "$files" ]] || return 1
    ! grep -Eqv "$LOCAL_GATE_PATHS" <<< "$files"
}

# _gate_step NAME COMMAND...: runs one local gate step in the clone with the loop environment,
# appends its output to $GATE_LOG and a table row to GATE_ROWS; sets GATE_RC=1 on failure.
_gate_step() {
    local name="$1" start=$SECONDS; shift
    printf '\n===== %s\n$ %s\n' "$name" "$*" >> "$GATE_LOG"
    if (cd "$REPO_DIR" && PYTHONPATH="$BUILD_DIR/python" Z3_EXE="$BUILD_DIR/z3" Z3_SOURCE="$REPO_DIR" \
            timeout "$((LOCAL_GATE_TIMEOUT_MIN * 60))" "$@" >> "$GATE_LOG" 2>&1); then
        GATE_ROWS+="| $name | pass | $(( SECONDS - start ))s |"$'\n'
    else
        GATE_ROWS+="| $name | **fail** | $(( SECONDS - start ))s |"$'\n'; GATE_RC=1
    fi
}

# run_local_gate: the steps of the CI job that exercise the loop's work (Python example tests,
# z3test proof script tests, the Lean-certified Boolean and QF_LRA matrices), run on this machine
# against the current build. Writes ITER_DIR/local-gate.log and ITER_DIR/LOCAL_GATE.md. Returns 0 on pass.
run_local_gate() {
    GATE_LOG="$ITER_DIR/local-gate.log" GATE_ROWS="" GATE_RC=0
    local art="$ITER_DIR/local-gate-artifacts" matrix="$ITER_DIR/local-gate-matrix.jsonl" lean="$Z3TEST_DIR/regressions/proofs/lean"
    : > "$GATE_LOG"; rm -rf "$art" "$matrix"
    _gate_step "Python example tests: certificate exporter" python3 -m unittest discover -s examples/python -p 'test_proof_certificate.py'
    _gate_step "Python example tests: Lean reconstruction" python3 -m unittest discover -s examples/python -p 'test_proof_to_lean*.py'
    _gate_step "z3test proof script tests" python3 -m unittest discover -s "$Z3TEST_DIR/scripts/proofs" -p 'test_proof*.py'
    _gate_step "Lean-certified Boolean matrix (legacy proof object)" python3 "$Z3TEST_DIR/scripts/proofs/proof_matrix.py" \
        --z3 "$BUILD_DIR/z3" --z3-source "$REPO_DIR" --lean --cells legacy-proof-object --timeout 30 \
        --lean-artifacts "$art" --out "$matrix" "$lean"/boolean_*.smt2 "$lean/unit_resolution.smt2"
    _gate_step "Lean-certified QF_LRA matrix (clause log)" python3 "$Z3TEST_DIR/scripts/proofs/proof_matrix.py" \
        --z3 "$BUILD_DIR/z3" --z3-source "$REPO_DIR" --lean --cells smt-clause-log-nopp --timeout 30 \
        --lean-artifacts "$art" --out "$matrix" "$lean"/lra_*.smt2
    {
        printf '## Local gate\n\n'
        printf 'This change touches only documentation, the Python examples, or the Lean project, so the loop merged it on its local gate instead of waiting for GitHub CI. The gate mirrors the steps of the `CI / Ubuntu build - cmake - releaseClang` job that exercise this work, run on the loop machine (%s) against the current Release build. GitHub CI still runs on `%s` after the merge.\n\n' \
            "$(uname -s) $(uname -m)" "$BASE_BRANCH"
        printf '| step | result | time |\n| --- | --- | --- |\n%s\n' "$GATE_ROWS"
        printf 'Result: **%s**. Changed files:\n\n' "$([[ $GATE_RC == 0 ]] && echo pass || echo FAIL)"
        repo_git diff --name-only "$(repo_git merge-base "origin/$BASE_BRANCH" HEAD)" HEAD | sed 's/^/- `/; s/$/`/'
    } > "$ITER_DIR/LOCAL_GATE.md"
    return $GATE_RC
}

# wait_for_ci PR OUT: polls checks until the gating workflows finish. Returns 0 pass, 1 fail, 2 timeout.
wait_for_ci() {
    local pr="$1" out="$2" start=$SECONDS status
    while :; do
        ghf pr checks "$pr" --json name,state,bucket,workflow,link,startedAt,completedAt > "$out.raw" 2>/dev/null || true
        status=$(python3 "$LOOP_DIR/tools/ci_status.py" "$out.raw" "$GATING_WORKFLOWS" \
            "$(( (SECONDS - start) / 60 ))" "$CI_SETTLE_MIN" "$out")
        case "$status" in
            pass) log "CI passed for PR #$pr ($(jq -r .gating_total "$out") gating checks)"; return 0 ;;
            fail) log "CI failed for PR #$pr: $(jq -r '.gating_failed | join(", ")' "$out")"; return 1 ;;
        esac
        if (( SECONDS - start > CI_TIMEOUT_MIN * 60 )); then
            log "CI wait timed out after $CI_TIMEOUT_MIN minutes"; return 2
        fi
        log "CI pending for PR #$pr: $(jq -r .gating_pending "$out")/$(jq -r .gating_total "$out") gating checks still running"
        sleep "$CI_POLL_SEC"
    done
}

# collect_ci_failures STATUS_JSON OUT: tails of failed job logs.
collect_ci_failures() {
    local status="$1" out="$2" name link run job
    : > "$out"
    jq -r '.gating[] | select(.bucket == "fail" or .bucket == "cancel") | "\(.workflow) / \(.name)\t\(.link)"' "$status" |
    while IFS=$'\t' read -r name link; do
        printf '===== %s\n%s\n' "$name" "$link" >> "$out"
        run=$(sed -n 's#.*/actions/runs/\([0-9]*\).*#\1#p' <<< "$link")
        job=$(sed -n 's#.*/job/\([0-9]*\).*#\1#p' <<< "$link")
        if [[ -n "$run" && -n "$job" ]]; then
            ghf run view "$run" --job "$job" --log-failed 2>/dev/null | tail -n 400 >> "$out" || printf '(log unavailable)\n' >> "$out"
        fi
        printf '\n' >> "$out"
    done
}

ensure_pages() {
    if ! repo_git ls-remote --exit-code --heads origin "$PAGES_BRANCH" >/dev/null 2>&1; then
        log "creating orphan $PAGES_BRANCH branch for reports"
        repo_git worktree prune
        repo_git worktree add -q --detach "$PAGES_DIR" "$BASE_BRANCH"
        git -C "$PAGES_DIR" checkout -q --orphan "$PAGES_BRANCH"
        git -C "$PAGES_DIR" rm -r -q -f . >/dev/null
        mkdir -p "$PAGES_DIR/reports"
        : > "$PAGES_DIR/.nojekyll"
        python3 "$LOOP_DIR/tools/make_index.py" "$PAGES_DIR"
        git -C "$PAGES_DIR" add -A
        git -C "$PAGES_DIR" commit -q -m "Initialize the loop report site"
        git -C "$PAGES_DIR" push -q -u origin "$PAGES_BRANCH"
    elif [[ ! -e "$PAGES_DIR/.git" ]]; then
        repo_git worktree prune
        repo_git fetch -q origin "$PAGES_BRANCH:$PAGES_BRANCH" 2>/dev/null || true
        repo_git worktree add -q "$PAGES_DIR" "$PAGES_BRANCH"
    fi
    git -C "$PAGES_DIR" pull -q --ff-only origin "$PAGES_BRANCH" 2>/dev/null || true
    if ! gh api "repos/$FORK/pages" >/dev/null 2>&1; then
        log "enabling GitHub Pages on $FORK from $PAGES_BRANCH"
        gh api -X POST "repos/$FORK/pages" -f build_type=legacy -f "source[branch]=$PAGES_BRANCH" -f "source[path]=/" >/dev/null \
            || log "warning: could not enable GitHub Pages via API"
    fi
}

# A PR must keep its numbered report and description link before becoming ready.
publish_report() {
    local pr="$1" path="reports/pr-$1" source
    local trailers=()
    [[ -z "${LOOP_COMMIT_TRAILERS:-}" ]] || trailers=(-m "$LOOP_COMMIT_TRAILERS")
    [[ "${PR_REPO:-$FORK}" == "$FORK" ]] || path="reports/upstream/pr-$pr"
    source="https://github.com/$FORK/blob/$PAGES_BRANCH/$path.html"
    mkdir -p "$PAGES_DIR/$(dirname "$path")" || return 1
    cp "$ITER_DIR/report.html" "$PAGES_DIR/$path.html" || return 1
    cp "$ITER_DIR/report-meta.json" "$PAGES_DIR/$path.json" || return 1
    python3 "$LOOP_DIR/tools/make_index.py" "$PAGES_DIR" || return 1
    git -C "$PAGES_DIR" add index.html "$path.html" "$path.json" || return 1
    if ! git -C "$PAGES_DIR" diff --cached --quiet; then
        git -C "$PAGES_DIR" commit -q -m "Report for ${PR_REPO:-$FORK}#$pr" "${trailers[@]}" || return 1
    fi
    git -C "$PAGES_DIR" push -q origin "$PAGES_BRANCH" || return 1
    local code="" i
    # Legacy Pages builds of this fork queue for up to 10 minutes and build for 5 to 15 more.
    # Request a new build only when the latest one actually failed: requesting one while a
    # build is in progress cancels it, and doing that every few minutes keeps the page down.
    local status
    for i in $(seq 1 100); do
        code=$(curl -sS -o "$ITER_DIR/published-report.html" -w '%{http_code}' "$REPORT_URL") || code="000"
        [[ "$code" == "200" ]] && cmp -s "$ITER_DIR/report.html" "$ITER_DIR/published-report.html" && break
        if (( i % 20 == 0 )); then
            status=$(gh api "repos/$FORK/pages/builds/latest" --jq .status 2>/dev/null || true)
            [[ "$status" == "errored" ]] && gh api -X POST "repos/$FORK/pages/builds" >/dev/null 2>&1
        fi
        sleep 15
    done
    log "report page $REPORT_URL (HTTP $code)"
    if [[ "$code" != "200" ]] || ! cmp -s "$ITER_DIR/report.html" "$ITER_DIR/published-report.html"; then
        log "report publication timed out; the PR will not be marked ready"
        return 1
    fi
    python3 "$LOOP_DIR/tools/report_body.py" "$ITER_DIR/PR_BODY.md" "$REPORT_URL" "$source" || return 1
    ghp pr edit "$pr" --body-file "$ITER_DIR/PR_BODY.md" >/dev/null || return 1
    ghp pr comment "$pr" --body "$(printf '## High-level report\n\n%s\n\nSource: %s (index: %s/)\n' \
        "$REPORT_URL" "$source" "$PAGES_URL")" >/dev/null
}
