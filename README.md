# Lean certificate improvement loop

An unattended loop that improves Z3's native proof certificates and their Lean
verification in the fork `levnach/z3`, one pull request per iteration.

## One iteration

1. **Rebase.** The fork's `master` is reset to the fork, rebased onto
   `Z3Prover/z3` `master`, and force-pushed (so the fork is always upstream
   plus the loop's merged PRs). Conflicts go to the `rebaser` agent.
2. **Build.** Incremental Release build of z3 with Python bindings in
   `repo/build`, plus the Lean project (`scripts/check_lean.sh`); z3test is
   updated.
3. **Implementer agent** picks the next improvement (guided by
   `doc/lean-proof-plan.md` and `state/BACKLOG.md`), implements and tests it,
   commits on `loop/iter-N`, and writes `CHANGE_SUMMARY.md`.
4. **Reviewer agent** reviews the diff read-only (soundness of the trust
   boundary first) and writes `REVIEW.md` with a verdict. Any repository
   change it makes is reverted.
5. **Integrator agent** judges both the change and the review, fixes what the
   review found, re-verifies, and writes `PR_TITLE.txt` and `PR_BODY.md`
   (or `ABORT.md`).
6. **Driver and report.** Prepare an HTML copy of the PR description before
   creating a draft. Once GitHub assigns its number, the reporter writes the
   high-level report while the gate (step 7) already runs. Publish
   `reports/pr-N.html` on `gh-pages`, wait until the exact HTML is live, and
   add its links to the PR description before marking the draft ready.
   Publication failure leaves the draft for `--resume`. Open reports must not
   claim a merge or completed CI. Only the driver pushes, opens, edits,
   merges, or comments. Commits to `gh-pages` take the `pages.lock` directory
   lock, since a background report refresh (step 9) may share the worktree.
7. **Gate.** If every changed file matches `LOCAL_GATE_PATHS` (documentation,
   the Python examples, the Lean project), the driver runs the local gate
   instead of GitHub CI: the Python example tests, the z3test proof script
   tests, and the Lean-certified Boolean and QF_LRA matrices, on this machine
   (`state/iter-NNN/LOCAL_GATE.md`, also posted as a PR comment). It runs in
   the background while the reporter works; the merge waits for both. Otherwise
   the driver waits for the gating workflows (CI, Windows, OCaml,
   WebAssembly, determinism). On failure the `ci_fixer` agent gets the failed
   logs and either fixes (push, wait again), proves the failure unrelated with
   evidence (merge anyway, with a PR comment), or gives up (PR left open, loop
   stops). At most `MAX_CI_FIX_ATTEMPTS` rounds.
8. **Merge.** Squash merge into the fork's `master`; the push triggers the
   master CI as well.
9. **Refresh report.** Update the same HTML page after merge with the actual
   merge and verification results. This runs in the background so that the
   next iteration starts right after the merge: the reporter works in a
   detached worktree of the merge commit under `work/report-pr-N` with a
   copy-on-write clone of the build directory, and logs to the iteration log.
   A failed refresh leaves the pre-merge page in place and writes
   `state/iter-NNN/REPORT_REFRESH_FAILED.md`; `report-refresh.pid` names the
   job while it runs. Reports live at
   `https://levnach.github.io/z3/reports/pr-N.html`, with an index at `/`.
   Corresponding upstream reports use `reports/upstream/pr-N.html`.

## Running

    ./loop.sh -n 2            # two iterations (two PRs)
    ./loop.sh --start 5 -n 1  # explicit iteration number
    ./loop.sh --skip-build    # reuse the existing build
    ./run_until_cpp.sh        # stop at a ready C++ PR, without merging it
    ./loop.sh --start 5 --resume --stop-on-cpp  # retry publication, reusing a draft

Loop helper tests: `python3 -m unittest discover -s tests`.

An interrupted iteration (reboot, kill) can be continued: save the clone's
diff as a patch under `state/iter-NNN/`, write `state/iter-NNN/RESUME_NOTE.md`
describing it, and start the loop at that iteration; the note is rendered
into the implementer prompt.

Logs: `logs/loop.log` (everything), `state/iter-NNN/iteration.log`
(per iteration), `state/iter-NNN/<role>.stream.log` (agent transcripts).
Results: `state/HISTORY.md`, `state/BACKLOG.md`, `state/iter-NNN/*`.

## Safety

- Sub-agents run headless with an explicit tool allowlist
  (`AGENT_ALLOWED_TOOLS` in `config.env`): git without push, python3, cmake,
  ninja, Lean tools, read-only `gh` queries, text utilities.
- The clone's `upstream` remote has pushing disabled; nothing in the loop can
  write to `Z3Prover/z3`.
- The agents never see `--dangerously-skip-permissions`.
- `tools/watchdog.py` kills orphaned, oversized, or overdue `lean` and loop-built
  `z3` processes (limits in `config.env`, kills in `state/watchdog.log`); it
  outlives `loop.sh` until no loop script or watched process remains.

## Layout

    config.env   settings (fork, gating workflows, timeouts, allowlist)
    loop.sh      driver
    lib.sh       helpers (agents, rebase, build, CI wait, pages)
    prompts/     one prompt per role: implementer, reviewer, integrator,
                 ci_fixer, reporter, rebaser
    tools/       prompt rendering, CI status, report rendering/linking, site index,
                 process watchdog
    tests/       report rendering and draft-publication flow regressions
    repo/        clone of the fork (origin) with upstream push-disabled
    z3test/      shallow clone of Z3Prover/z3test
    pages/       worktree of the gh-pages branch
    state/       per-iteration artifacts and the loop history
