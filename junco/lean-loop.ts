/**
 * Lean certificate improvement loop as a Junco workflow; see lean-loop.yml for the round graph.
 *
 * The runner builds one graph per round over fresh agents (TestGenerator, Implementer, Reviewer),
 * like loop.sh's one headless session per role and iteration; round state lives on disk under
 * seed/state. A failed round throws and ends the loop (loop.sh dies on a failed iteration too);
 * SIGINT exits 130.
 *
 * Usage: systemd-run --user --scope -p Delegate=yes -- bun run lean-loop.ts [--rounds N] [--no-pr] [--skip-build]
 * (marsh, junco's agent shell, needs a delegated cgroup v2 subtree; outside one every external
 * command of the agents fails closed with "cgroup resource control unavailable".)
 * Prerequisites: Bun 1.4.2, the adjacent ../../junco checkout with its native addon, a btrfs
 * seed subvolume at ./seed (`btrfs subvolume create seed`) holding a clone of the fork at
 * ./seed/repo (origin = fork, upstream push DISABLED), gh logged in as the fork owner unless --no-pr,
 * cmake/ninja/python3/elan on PATH, a saved GitHub Copilot Pi login for the pinned model, Grafana
 * at GRAFANA_URL (default http://localhost:8000) and Opik configured through OPIK_* / ~/.opik.config.
 * Settings (FORK, BASE_BRANCH, BUILD_JOBS) come from ../config.env, shared with loop.sh.
 */
import { existsSync } from "node:fs";
import { appendFile, mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { OpikTracer } from "dataflow-engine-opik";
import { graph, JuncoGraph, schedules, syntax, tools, tracer } from "junco";
import { Opik } from "opik";
import type { TSchema } from "typebox";
import source from "./lean-loop.yml" with { type: "text" };

const here = fileURLToPath(new URL(".", import.meta.url));
/** Parsed at import: schema, edge and trigger errors surface before any model or repository access. */
export const document = syntax.parse(source);

/** Opik project and trace name, Grafana dashboard UID. */
const INSTANCE = "Z3-lean-checker";

// Verified 2026-11-05 against the saved Copilot catalog (latest Opus listed) and supported thinking levels.
// https://www.anthropic.com/news/claude-opus-5-5
const provider = "github-copilot";
export const LADDER = schedules.uniformLadder({ model: `${provider}/claude-opus-5.5`, thinking: "high" });

const paths = {
  seed: join(here, "seed"),
  repoDir: join(here, "seed", "repo"),
  buildDir: join(here, "seed", "repo", "build"),
  z3testDir: join(here, "seed", "z3test"),
  stateDir: join(here, "seed", "state"),
};

export type Role = "TestGenerator" | "Implementer" | "Reviewer";

/** Run-long state; beginRound advances the branch and paths, OpenPR fills `pr` and `reviewBase`. */
export type Round = {
  iter: number;
  branch: string;
  baseSha: string;
  readonly baseBranch: string;
  readonly fork: string;
  readonly repoDir: string;
  readonly buildDir: string;
  readonly z3testDir: string;
  readonly stateDir: string;
  roundDir: string;
  readonly noPr: boolean;
  pr?: { number: number; url: string };
  reviewBase?: string;
};

export const HISTORY_HEADER = "# Loop history\n\n| round | finished | PR | head | review |\n| --- | --- | --- | --- | --- |\n";

const git = (round: Round, ...args: string[]) => Bun.$`git -C ${round.repoDir} ${args}`.quiet();
const gh = (round: Round, ...args: string[]) => Bun.$`gh -R ${round.fork} ${args}`.cwd(round.roundDir).quiet();

async function head(round: Round): Promise<string> {
  return (await git(round, "rev-parse", "HEAD")).text().trim();
}

/** loop.sh commit_leftovers: the branch must carry the complete change. */
async function commitLeftovers(round: Round, who: string): Promise<void> {
  if (!(await git(round, "status", "--porcelain")).text().trim()) return;
  await git(round, "add", "-A");
  await git(round, "commit", "-q", "-m", `Loop driver: include changes left uncommitted by the ${who}`);
}

async function readRequired(round: Round, file: string, who: Role): Promise<string> {
  const path = join(round.roundDir, file);
  const text = existsSync(path) ? (await readFile(path, "utf8")).trim() : "";
  if (!text) throw new Error(`${who} wrote no ${file} in ${round.roundDir}`);
  return text;
}

/** The "Where you are" block of every assignment (loop.sh renders it into each prompt). */
export function whereYouAre(round: Round): string {
  return [
    `Round ${round.iter}. Repository: ${round.repoDir}, a clone of the fork ${round.fork} (origin; upstream Z3Prover/z3 has pushing disabled). Branch \`${round.branch}\`, created from \`${round.baseBranch}\` at ${round.baseSha}.`,
    `Z3 is built in ${round.buildDir} (Release, Python bindings). Before Python tests run: \`export PYTHONPATH=${round.buildDir}/python Z3_EXE=${round.buildDir}/z3 Z3_SOURCE=${round.repoDir}\` (repeat it in every shell command; shells do not persist). Rebuild with \`cmake --build ${round.buildDir} --parallel 12\`.`,
    `z3test checkout (reference only): ${round.z3testDir}. Loop state: ${round.stateDir} (BACKLOG.md, earlier rounds under iter-*/). Round dir for your files: ${round.roundDir}.`,
    `Shell use is restricted by role: git without push, python3, cmake, ninja, the Lean tools, read-only gh queries, and Unix text utilities. Never push, never open or edit pull requests, never touch master or any remote; the driver does that.`,
  ].join("\n");
}

/** Sync the fork's base branch, create the round branch and dir; returns the TestGenerator's assignment. */
export async function beginRound(round: Round, iter: number): Promise<string> {
  await git(round, "fetch", "-q", "origin", round.baseBranch);
  await git(round, "checkout", "-q", "-f", round.baseBranch);
  await git(round, "reset", "-q", "--hard", `origin/${round.baseBranch}`);
  const branch = `loop/junco-${iter}`;
  await git(round, "checkout", "-q", "-B", branch, round.baseBranch);
  round.iter = iter;
  round.branch = branch;
  round.baseSha = await head(round);
  round.roundDir = join(round.stateDir, `iter-${String(iter).padStart(3, "0")}`);
  round.pr = undefined;
  round.reviewBase = undefined;
  await mkdir(join(round.roundDir, "scratch"), { recursive: true });
  return `${whereYouAre(round)}\n\nPick one coverage gap of the Z3 -> Lean certificate pipeline, pin it with tests committed on \`${round.branch}\` that fail against the current build, and write ${round.roundDir}/TESTS.md.`;
}

/**
 * A driver step: validate `who`'s report delivered on value edge `input`, run the round's
 * bookkeeping, and return the next role's assignment (or, for PostReview, the review) on the
 * node's outbound value edge.
 */
function step(input: string, who: Role, work: (round: Round, report: string) => Promise<unknown>): syntax.DeterministicNode<Round> {
  const IN = graph.EdgeId.create(input);
  return ({ policy, context: round }) => ({
    state: new graph.nodes.Deterministic<TSchema, unknown>(async function* (signal) {
      const inputs = yield [];
      signal.throwIfAborted();
      return await work(round, syntax.finalText(inputs.values.get(IN), who));
    }, policy),
  });
}

const assignment = (text: string) => ({ kind: "prompt", text }) as const;

/** Validate the tests round and admit the Implementer. */
export const PrepareImplementer = step("TestGenerator->PrepareImplementer", "TestGenerator", async (round, report) => {
  await commitLeftovers(round, "test generator");
  if ((await head(round)) === round.baseSha) throw new Error("TestGenerator committed no tests");
  const tests = await readRequired(round, "TESTS.md", "TestGenerator");
  return assignment(`${whereYouAre(round)}\n\nTest generator report (evidence):\n${report}\n\n${round.roundDir}/TESTS.md:\n${tests}\n\nMake these committed tests pass with the smallest sound change, verify, commit, and write CHANGE_SUMMARY.md, PR_TITLE.txt and PR_BODY.md in the round dir.`);
});

/** loop.sh step 4: push the branch and open the PR on the fork; the Reviewer gets the PR. */
export const OpenPR = step("Implementer->OpenPR", "Implementer", async (round, report) => {
  await commitLeftovers(round, "implementer");
  const abort = join(round.roundDir, "ABORT.md");
  if (existsSync(abort)) throw new Error(`Implementer aborted the round: ${(await readFile(abort, "utf8")).split("\n").slice(0, 3).join(" ")}`);
  const title = (await readRequired(round, "PR_TITLE.txt", "Implementer")).split("\n")[0]!;
  await readRequired(round, "PR_BODY.md", "Implementer");
  if (!round.noPr) {
    await git(round, "push", "-q", "-u", "origin", round.branch, "--force-with-lease");
    const url = (await gh(round, "pr", "create", "--base", round.baseBranch, "--head", round.branch, "--title", title, "--body-file", join(round.roundDir, "PR_BODY.md"))).text().trim();
    const number = Number(url.split("/").pop());
    if (!Number.isInteger(number)) throw new Error(`gh pr create returned no PR URL: ${url}`);
    round.pr = { number, url };
    await writeFile(join(round.roundDir, "pr.json"), (await gh(round, "pr", "view", String(number), "--json", "number,url,title,headRefOid,createdAt")).text());
  }
  round.reviewBase = await head(round);
  const where = round.pr ? `Pull request: ${round.pr.url} (#${round.pr.number}); its diff is \`git diff ${round.baseSha}...HEAD\`.` : `No pull request was opened (the loop runs with --no-pr); review the branch: \`git diff ${round.baseSha}...HEAD\`.`;
  return assignment(`${whereYouAre(round)}\n\n${where}\nPR title: ${title}\n\nImplementer report (evidence):\n${report}\n\nRead ${round.roundDir}/TESTS.md, CHANGE_SUMMARY.md and PR_BODY.md, verify the claims, and reply with the review; first line VERDICT: APPROVE or VERDICT: REQUEST_CHANGES.`);
});

/** Record the review, discard anything the Reviewer changed, post the verdict on the PR; the review reaches $sink and ends the round. */
export const PostReview = step("Reviewer->PostReview", "Reviewer", async (round, report) => {
  let review = report;
  if ((await head(round)) !== round.reviewBase || (await git(round, "status", "--porcelain")).text().trim()) {
    await git(round, "reset", "-q", "--hard", round.reviewBase!);
  }
  const verdict = /^VERDICT: (APPROVE|REQUEST_CHANGES)\b/.exec(review)?.[1];
  if (!verdict) review = `VERDICT: REQUEST_CHANGES\n\n## Summary\nThe reviewer produced no verdict line; its final message follows.\n\n${review}`;
  await writeFile(join(round.roundDir, "REVIEW.md"), `${review}\n`);
  // A comment, not `gh pr review`: GitHub rejects approving/requesting changes on one's own PR.
  if (round.pr) await gh(round, "pr", "comment", String(round.pr.number), "--body-file", join(round.roundDir, "REVIEW.md"));
  await appendFile(join(round.stateDir, "HISTORY.md"), `| ${round.iter} | ${new Date().toISOString().slice(0, 16)} | ${round.pr ? `[#${round.pr.number}](${round.pr.url})` : "(no PR: --no-pr)"} | ${round.baseSha.slice(0, 9)}..${(await git(round, "rev-parse", "--short", "HEAD")).text().trim()} | ${review.split("\n")[0]} |\n`);
  return review;
});

/** loop.sh preflight: the seed clone, its remotes and z3test. */
async function preflight(signal: AbortSignal): Promise<void> {
  if (!existsSync(paths.seed) || (await stat(paths.seed)).ino !== 256) throw new Error(`${paths.seed} is not a btrfs subvolume; run: btrfs subvolume create ${paths.seed}`);
  if (!existsSync(join(paths.repoDir, ".git"))) throw new Error(`clone the fork into ${paths.repoDir} first`);
  if ((await Bun.$`git -C ${paths.repoDir} remote get-url --push upstream`.quiet()).text().trim() !== "DISABLED") throw new Error("upstream remote must have pushing disabled");
  if (!existsSync(join(paths.z3testDir, ".git"))) await Bun.$`git clone -q --depth 1 https://github.com/Z3Prover/z3test.git ${paths.z3testDir}`.quiet();
  else await Bun.$`git -C ${paths.z3testDir} pull -q --ff-only`.quiet().nothrow();
  signal.throwIfAborted();
}

/** loop.sh build_z3, after the round's base sync: the Release build and the Lean project; logs in the round dir. */
async function build(round: Round, buildJobs: string): Promise<void> {
  if (!existsSync(join(round.buildDir, "CMakeCache.txt"))) {
    console.error(`configuring z3 build in ${round.buildDir}`);
    await writeFile(join(round.roundDir, "configure.log"), await Bun.$`cmake -G Ninja -S ${round.repoDir} -B ${round.buildDir} -DCMAKE_BUILD_TYPE=Release -DZ3_BUILD_PYTHON_BINDINGS=ON`.quiet().text());
  }
  console.error(`building z3 (log: ${round.roundDir}/build.log)`);
  await writeFile(join(round.roundDir, "build.log"), await Bun.$`cmake --build ${round.buildDir} --parallel ${buildJobs}`.quiet().text());
  console.error(`building the Lean project (log: ${round.roundDir}/lean-build.log)`);
  await writeFile(join(round.roundDir, "lean-build.log"), await Bun.$`./scripts/check_lean.sh`.cwd(round.repoDir).quiet().text());
}

/** `rounds` rounds (default forever): one graph per round, closed before the next begins. */
export async function runLoop(ladder: schedules.ModelLadder, observer: tracer.DataflowTracer, recorder: syntax.BuildOptions["recorder"], signal: AbortSignal,
  settings: Pick<Round, "baseBranch" | "fork" | "noPr"> & { rounds: number; skipBuild: boolean; buildJobs: string }): Promise<void> {
  const history = join(paths.stateDir, "HISTORY.md");
  if (!existsSync(history)) await writeFile(history, HISTORY_HEADER);
  const done = (await readdir(paths.stateDir)).map((d) => Number(/^iter-(\d+)$/.exec(d)?.[1])).filter(Number.isInteger);
  const { rounds, skipBuild, buildJobs, ...config } = settings;
  const round: Round = { iter: Math.max(0, ...done), branch: "", baseSha: "", roundDir: "", ...config, ...paths };
  for (let n = 0; n < rounds; n++) {
    signal.throwIfAborted();
    const text = await beginRound(round, round.iter + 1);
    console.error(`=== round ${round.iter}: branch ${round.branch} from ${round.baseSha.slice(0, 9)} ===`);
    if (!skipBuild) await build(round, buildJobs);
    signal.throwIfAborted();
    // ponytail: EmptyPolicy because roles run strictly one after another on one branch; LockPolicy
    // would make the Implementer wait on files the TestGenerator wrote until it released them.
    const execution = await JuncoGraph.fromYaml(document, {
      cwd: paths.repoDir, scheduler: () => schedules.parallel(), ladder, policy: tools.EmptyPolicy, tracer: observer, recorder,
      context: round, signal, code: { PrepareImplementer, OpenPR, PostReview },
    });
    try {
      execution.graph.source.enqueue({ messages: new Map([[graph.EdgeId.create("start"), [{ kind: "prompt", text }]]]), values: new Map() });
      const results = await execution.run({ signal });
      if (!results.has(graph.NodeId.create("PostReview"))) throw new Error(`round ${round.iter} quiesced before PostReview recorded a review`);
      console.error(`round ${round.iter} done: ${String(results.get(graph.NodeId.create("PostReview"))).split("\n")[0]}`);
    } finally {
      await execution.graph.close();
    }
  }
}

export async function main(args: readonly string[], signal: AbortSignal): Promise<void> {
  const config = Object.fromEntries(
    [...(await readFile(join(here, "..", "config.env"), "utf8")).matchAll(/^(FORK|BASE_BRANCH|BUILD_JOBS)="?([^"\s#]+)/gm)].map((m) => [m[1], m[2]]),
  ) as { FORK: string; BASE_BRANCH: string; BUILD_JOBS: string };
  const noPr = args.includes("--no-pr"), skipBuild = args.includes("--skip-build");
  if (!noPr) {
    const login = (await Bun.$`gh api user -q .login`.quiet().text()).trim();
    if (!config.FORK.startsWith(`${login}/`)) throw new Error(`gh is logged in as ${login}, but the fork is ${config.FORK}; use --no-pr or log in as the fork owner`);
  }
  const models = await ModelRuntime.create({ allowModelNetwork: true, refreshOnCreate: false, signal });
  let refreshed = await models.refresh({ allowNetwork: true, signal });
  // The cold Copilot token exchange regularly overruns pi-ai's 5 s catalog timeout once; the warm retry takes ~2 s.
  if (!refreshed.aborted && refreshed.errors.size > 0) refreshed = await models.refresh({ allowNetwork: true, signal });
  if (refreshed.aborted || refreshed.errors.size > 0) {
    throw new AggregateError([
      ...(refreshed.aborted ? [new Error("Model catalog refresh aborted")] : []),
      ...[...refreshed.errors].map(([provider, error]) => new Error(`${provider}: ${error.message}`, { cause: error })),
    ], "Model catalog refresh failed");
  }
  if (!(await models.listCredentials({ signal })).some(({ providerId }) => providerId === provider)) throw new Error(`no saved Pi login for provider ${provider}`);
  const ladder = new schedules.ModelLadder(models, LADDER); // rejects models absent from the catalog or unsupported thinking
  await preflight(signal);
  const rounds = Number(args[args.indexOf("--rounds") + 1] || Infinity);
  process.env.PYTHONPATH = join(paths.buildDir, "python");
  process.env.Z3_EXE = join(paths.buildDir, "z3");
  process.env.Z3_SOURCE = paths.repoDir;
  // Opik: one trace per round, one span per node activation. Local junco stack unless OPIK_URL_OVERRIDE says otherwise.
  const observer = new OpikTracer(new Opik({ apiUrl: process.env.OPIK_URL_OVERRIDE ?? "http://localhost:5173/api", projectName: INSTANCE }), INSTANCE);
  // Grafana: one metrics session for the whole run on the managed dashboard INSTANCE.
  const recorder = await tracer.GrafanaRecorder.create({ url: process.env.GRAFANA_URL, dashboard: INSTANCE });
  console.error(`grafana: ${recorder.dashboardUrl}`);
  try {
    await runLoop(ladder, observer, recorder, signal, { baseBranch: config.BASE_BRANCH, fork: config.FORK, noPr, rounds, skipBuild, buildJobs: config.BUILD_JOBS });
  } finally {
    await recorder.close();
  }
}

if (import.meta.main) {
  const interrupt = new AbortController();
  process.once("SIGINT", () => interrupt.abort(new Error("SIGINT")));
  try {
    await main(process.argv.slice(2), interrupt.signal);
  } catch (error) {
    console.error(error);
    process.exitCode = interrupt.signal.aborted ? 130 : 1;
  }
}
