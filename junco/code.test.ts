import { test } from "bun:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { graph, type syntax, tools } from "junco";
import { beginRound, document, HISTORY_HEADER, OpenPR, PostReview, PrepareImplementer, type Round } from "./lean-loop.ts";

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const report = (text: string): AssistantMessage => ({ role: "assistant", stopReason: "stop", content: [{ type: "text", text }], api: "test", provider: "test", model: "test", usage, timestamp: 0 });

/** The text of an assignment a code node returned for the next agent. */
function promptText(value: unknown): string {
  assert.ok(value && typeof value === "object" && "kind" in value && value.kind === "prompt" && "text" in value && typeof value.text === "string", `not an assignment: ${JSON.stringify(value)}`);
  return value.text;
}

/** One fresh code node per round: prime it, resume it with the report, take its return. */
async function run(node: syntax.DeterministicNode<Round>, round: Round, input: string, message: AssistantMessage): Promise<unknown> {
  const { state } = await node({ context: round, policy: tools.EmptyPolicy, graph: undefined as never, label: "check", node: "check", edges: new Map() });
  try {
    await state.next();
    const step = await state.next({ values: new Map([[graph.EdgeId.create(input), message]]), messages: new Map() });
    assert.equal(step.done, true, "driver nodes return once per round");
    return step.value;
  } finally {
    await state.close();
  }
}

test("driver nodes validate reports, hand each role its assignment and record the review", async () => {
  assert.deepEqual(Object.keys(document.graph.nodes), ["TestGenerator", "PrepareImplementer", "Implementer", "OpenPR", "Reviewer", "PostReview"]);
  const root = await mkdtemp(join(tmpdir(), "lean-loop-"));
  const repoDir = join(root, "repo"), origin = join(root, "origin.git");
  const git = (...args: string[]) => Bun.$`git -C ${repoDir} ${args}`.quiet();
  const round: Round = { iter: 0, branch: "", baseSha: "", roundDir: "", baseBranch: "master", fork: "test/fork", repoDir, buildDir: "build", z3testDir: "z3test", stateDir: root, noPr: true };
  try {
    await Bun.$`git init -q --bare ${origin}`.quiet();
    await Bun.$`git init -q -b master ${repoDir}`.quiet();
    await git("config", "user.name", "Loop check");
    await git("config", "user.email", "check@example.invalid");
    await writeFile(join(repoDir, "base"), "base\n");
    await git("add", ".");
    await git("commit", "-qm", "base");
    await git("remote", "add", "origin", origin);
    await git("push", "-q", "origin", "master");
    await writeFile(join(root, "HISTORY.md"), HISTORY_HEADER);
    for (const iter of [1, 2]) {
      assert.match(await beginRound(round, iter), new RegExp(`^Round ${iter}\\.`));
      assert.equal((await git("branch", "--show-current")).text().trim(), `loop/junco-${iter}`);
      const roundDir = round.roundDir;
      await assert.rejects(run(PrepareImplementer, round, "TestGenerator->PrepareImplementer", report("Wrote nothing")), /committed no tests/);
      await writeFile(join(repoDir, "tests"), `round ${iter}\n`);
      await writeFile(join(roundDir, "TESTS.md"), "Failing coverage test\n");
      const toImplementer = await run(PrepareImplementer, round, "TestGenerator->PrepareImplementer", report("Pinned the gap"));
      assert.match(promptText(toImplementer), /Pinned the gap[\s\S]*Failing coverage test/);
      assert.equal((await git("status", "--porcelain")).text(), "", "leftover tests are committed");
      await writeFile(join(roundDir, "PR_TITLE.txt"), "Close coverage gap\n");
      await writeFile(join(roundDir, "PR_BODY.md"), "Verified change\n");
      const toReviewer = await run(OpenPR, round, "Implementer->OpenPR", report("Implemented"));
      assert.match(promptText(toReviewer), /--no-pr[\s\S]*PR title: Close coverage gap/);
      assert.equal(round.pr, undefined);
      await writeFile(join(repoDir, "tests"), "reviewer edit to discard\n");
      const review = await run(PostReview, round, "Reviewer->PostReview", report("No verdict supplied"));
      assert.match(review as string, /^VERDICT: REQUEST_CHANGES[\s\S]*No verdict supplied/);
      assert.equal(await readFile(join(repoDir, "tests"), "utf8"), `round ${iter}\n`, "reviewer edits are discarded");
      assert.match(await readFile(join(root, "HISTORY.md"), "utf8"), new RegExp(`\\| ${iter} \\| .*\\| VERDICT: REQUEST_CHANGES \\|`));
    }
    await writeFile(join(round.roundDir, "ABORT.md"), "Cannot close the gap soundly\n");
    await assert.rejects(run(OpenPR, round, "Implementer->OpenPR", report("Aborted implementation")), /Implementer aborted the round: Cannot close the gap soundly/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
