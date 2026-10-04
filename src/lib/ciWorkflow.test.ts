import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// The CI workflow's TRIGGERS are a duplication decision, and nothing guarded them before this file.
// Measured 2026-08-16: 440 runs in seven days, 209 of them `push` and 227 `pull_request`, so about
// half of every run this repository made was a second look at code that had already passed.
//
// This comment used to call it a MONEY decision, on the reasoning that those runs came close to the
// 2,000 monthly minutes a private repo gets on a free personal plan. The repository is PUBLIC
// (checked 2026-08-29) and GitHub does not bill a public repository for standard hosted runners, so
// no run here has ever cost money. That does not make a duplicate run free: on a free public
// repository the budget is the runner concurrency limit, and a job is priced in the slots it holds
// and the queue time it imposes on everything else (L307). The rule below is unchanged and never
// rested on either reading: what a push run buys is a weaker copy of a check the local merge scripts
// already make on the merged result (#3233, L32).
//
// The comments are stripped before any of this matches, deliberately. A guard that is satisfied by
// prose ABOUT the rule is indistinguishable from one that works, and the block below deliberately
// explains itself at length using the very words being searched for (L103).

const repoRoot = join(__dirname, "..", "..");
const raw = readFileSync(join(repoRoot, ".github", "workflows", "ci.yml"), "utf8");

/** The workflow with every comment removed, so no assertion here can be answered by prose. */
const source = raw
  .split("\n")
  .map((line) => line.replace(/(^|\s)#.*$/, ""))
  .join("\n");

/** The body of the top level `on:` block: its lines up to the next unindented key. */
function triggerBlock(): string {
  const lines = source.split("\n");
  const start = lines.findIndex((l) => /^on:\s*$/.test(l));
  expect(start, "ci.yml must declare a top level `on:` block").toBeGreaterThanOrEqual(0);
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((l) => /^\S/.test(l));
  return (end === -1 ? rest : rest.slice(0, end)).join("\n");
}

describe("the CI workflow's triggers", () => {
  it("runs on pull_request, which is what actually gates a merge", () => {
    expect(triggerBlock()).toMatch(/^\s{2}pull_request:/m);
  });

  it("does NOT run on push, because a push to main is a merge its own PR already ran", () => {
    // The only thing that can push to main here is a merge (scripts/hooks/pre-push refuses a push
    // whose destination is main), and that merge's PR ran this exact job. The stronger check on the
    // MERGED result, which a PR run genuinely cannot make (L85), is the local one:
    // verify-and-merge-branch.sh and verify-and-merge-batch.sh both merge origin/main into the
    // branch and run the whole suite before anything merges. So a push trigger here buys a second,
    // weaker copy of a check that already happened, for half of every run this repository makes.
    expect(triggerBlock()).not.toMatch(/^\s{2}push:/m);
  });

  it("runs the Mac suite, on a hosted macOS runner", () => {
    // The Swift tests were the ONLY thing gating this app and they ran nowhere automated between
    // #1347 (2026-07-22) and this change. #1347 offered two ways out of a self hosted runner that kept
    // dropping mid job, "(a) retiring swift-tests and relying on the local pre-push test gate ... or
    // (b) moving Swift tests onto a GitHub-hosted macOS runner", and took (a). Nothing on that issue
    // or in commit 610f807e records a reason for rejecting (b), and the premise that would have
    // justified it is false: this repository is PUBLIC, and GitHub's own billing documentation says
    // "The use of standard GitHub-hosted runners is free: In public repositories". So the Mac suite
    // could have been running in CI the whole time, on an image matching the Mac it is written on.
    //
    // Asserted on the RUNNER LABEL rather than on the job name, because the name is what a branch
    // ruleset keys on and renaming it is a separate decision (L305), while the label is what decides
    // whether any Swift runs at all.
    const macJob = /runs-on:\s*macos-[0-9]+\s*$/m;
    expect(source, "no job runs on a macOS runner, so no Swift test runs in CI at all").toMatch(macJob);
    expect(source, "the macOS job never invokes the Mac test runner").toMatch(/run-tests-locked\.sh/);
  });

  it("gives every job an explicit timeout, so a wedged one cannot hold a slot for six hours", () => {
    // L313, and it matters more for the macOS job than the ubuntu one: on a free public repository
    // the budget is the runner concurrency limit, so a job is priced in the slots it holds times how
    // long it holds them. A job with no timeout inherits GitHub's six hour default.
    // Scoped to the `jobs:` block. The first version counted every two space key in the file, so
    // `pull_request:` under `on:` read as a job and the guard demanded a timeout for a trigger. It
    // failed for that reason before it ever measured a job, which is the failure looking exactly like
    // the one it exists to report (L11).
    const lines = source.split("\n");
    const jobsAt = lines.findIndex((l) => /^jobs:\s*$/.test(l));
    expect(jobsAt, "ci.yml declares no `jobs:` block").toBeGreaterThanOrEqual(0);
    const after = lines.slice(jobsAt + 1);
    const endsAt = after.findIndex((l) => /^\S/.test(l));
    const block = endsAt === -1 ? after : after.slice(0, endsAt);
    const jobLines = block.filter((l) => /^\s{2}\S[^:]*:\s*$/.test(l));
    const timeouts = block.filter((l) => /^\s+timeout-minutes:/.test(l));
    expect(jobLines.length, "no job found, so this guard measured nothing").toBeGreaterThan(0);
    expect(timeouts.length, `${jobLines.length} job(s) declared, ${timeouts.length} timeout(s)`)
      .toBe(jobLines.length);
  });

  it("compiles the Release configuration, which the Mac suite never builds", () => {
    // `xcodebuild test` builds Debug, so a symbol declared inside `#if DEBUG` and used outside it
    // passes the whole suite. On 2026-09-24 exactly that (#4204's unguarded QueueRenderCounter calls)
    // merged green and was first built by the Update button, which failed. The step has to be in the
    // macOS job specifically: the Ubuntu job has no Xcode and would only ever report it unmeasured.
    const lines = source.split("\n");
    const macAt = lines.findIndex((l) => /runs-on:\s*macos-[0-9]+\s*$/.test(l));
    expect(macAt, "no job runs on a macOS runner").toBeGreaterThanOrEqual(0);
    const after = lines.slice(macAt + 1);
    const nextJob = after.findIndex((l) => /^\s{2}\S[^:]*:\s*$/.test(l) || /^\S/.test(l));
    const macJob = (nextJob === -1 ? after : after.slice(0, nextJob)).join("\n");
    expect(macJob, "the macOS job never compiles the Release configuration").toMatch(
      /run:\s*mac\/scripts\/check-release-compiles\.sh/,
    );
  });

  it("gives the Mac job room for the one retry the runner takes after a host crash (#4444)", () => {
    // `run-tests-locked.sh` retries a run whose host crashed, once. Measured 2026-10-04 (run 37213143450):
    // the suite step took 38 minutes, its tests 20 of them, and the Release compile after it 4 more. A
    // retry repeats the tests on an already built tree, so a retried run needs about 38 + 22 + 4 = 64
    // minutes, and a 60 minute job limit would kill exactly the run the retry exists to rescue.
    const lines = source.split("\n");
    const at = lines.findIndex((l) => /^\s{2}swift-tests:\s*$/.test(l));
    expect(at, "no swift-tests job").toBeGreaterThanOrEqual(0);
    const after = lines.slice(at + 1);
    const nextJob = after.findIndex((l) => /^\s{2}\S[^:]*:\s*$/.test(l) || /^\S/.test(l));
    const job = nextJob === -1 ? after : after.slice(0, nextJob);
    const timeout = job.map((l) => /^\s+timeout-minutes:\s*(\d+)\s*$/.exec(l)).find((m) => m !== null);
    expect(timeout, "swift-tests declares no timeout-minutes").toBeDefined();
    expect(Number(timeout?.[1])).toBeGreaterThanOrEqual(80);
  });

  it("scans every commit of a pull request for a real-arm file, over full history (#4328)", () => {
    // A real-arm file is a hashed snapshot of Dan's real data. The pre-push hook refuses one, but a hook can
    // be skipped with --no-verify and this repository is public, so CI walks the pull request's COMMITS,
    // which needs the full history: a shallow checkout would leave the range unreadable, and the scan
    // refuses that as unmeasured rather than passing it.
    expect(source, "no job runs scripts/real-arm-scan.sh over the pull request's base and head").toMatch(
      /run:\s*scripts\/real-arm-scan\.sh\s+"\$BASE_SHA"\s+"\$HEAD_SHA"/,
    );
    expect(source).toMatch(/BASE_SHA:\s*\$\{\{\s*github\.event\.pull_request\.base\.sha\s*\}\}/);
    expect(source).toMatch(/HEAD_SHA:\s*\$\{\{\s*github\.event\.pull_request\.head\.sha\s*\}\}/);
    const lines = source.split("\n");
    const at = lines.findIndex((l) => /^\s{2}real-arm-scan:\s*$/.test(l));
    expect(at, "no real-arm-scan job").toBeGreaterThanOrEqual(0);
    const after = lines.slice(at + 1);
    const next = after.findIndex((l) => /^\s{2}\S[^:]*:\s*$/.test(l) || /^\S/.test(l));
    const job = (next === -1 ? after : after.slice(0, next)).join("\n");
    expect(job, "the real-arm scan checks out a shallow history").toMatch(/fetch-depth:\s*0\b/);
    // The job names a script, and a pointer to a missing file runs nothing (L1004).
    expect(existsSync(join(repoRoot, "scripts", "real-arm-scan.sh"))).toBe(true);
  });

  it("keeps the job on a GitHub hosted runner, never a self hosted one", () => {
    // #1347 retired the self hosted Mac runner after it repeatedly went offline mid job and stalled
    // every merge. Guarding it here so a future edit cannot quietly bring one back.
    expect(source).not.toMatch(/self-hosted/);
  });
});
