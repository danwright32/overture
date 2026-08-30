import { readFileSync } from "node:fs";
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

  it("keeps the job on a GitHub hosted runner, never a self hosted one", () => {
    // #1347 retired the self hosted Mac runner after it repeatedly went offline mid job and stalled
    // every merge. Guarding it here so a future edit cannot quietly bring one back.
    expect(source).not.toMatch(/self-hosted/);
  });
});
