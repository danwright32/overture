import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// The CI workflow's TRIGGERS are a cost decision as much as a safety one, and nothing guarded them
// before this file. Measured 2026-08-16: 440 runs in seven days, 209 of them `push` and 227
// `pull_request`. GitHub bills a whole minute minimum per run however short it is, so that is about
// 1,890 billed minutes against the 2,000 a private repo gets on a free personal plan, and the
// default spending limit is zero, which means CI STOPS rather than bills. Halving it is what makes
// the repository affordable to keep private.
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
    // weaker copy of a check that already happened, at half the repository's CI budget.
    expect(triggerBlock()).not.toMatch(/^\s{2}push:/m);
  });

  it("keeps the job on a GitHub hosted runner, never a self hosted one", () => {
    // #1347 retired the self hosted Mac runner after it repeatedly went offline mid job and stalled
    // every merge. Guarding it here so a future edit cannot quietly bring one back.
    expect(source).not.toMatch(/self-hosted/);
  });
});
