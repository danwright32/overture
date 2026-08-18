import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// #612: the prep runbook is the prompt. It is prose, read by an AI that then writes emails Dan
// actually sends, so an instruction sitting in it is a live instruction, not documentation.
//
// It used to tell the drafter it could "link the contract page" as one arm of an A/B test. Dan's site
// has no contract, pricing, or rates page, so the only way to obey that instruction is to INVENT a
// URL, and the result is a 404 in a cold pitch to a stranger. The variant was never real; it just
// looked like a working feature.
//
// A prose instruction has no compiler and no type to protect it. This is the closest thing: the
// runbook may not carry that instruction back, and it must positively carry the prohibition, so a
// future edit that drops the warning is caught rather than quietly re-enabling the trap.

const repoRoot = join(__dirname, "..", "..");
const runbook = readFileSync(join(repoRoot, "docs", "prep-runbook.md"), "utf8");
const plan = readFileSync(join(repoRoot, "PLAN.md"), "utf8");

// Sentences that would send the drafter looking for a page that does not exist. Matched only when
// they read as an INSTRUCTION to link one, not when they appear in the prohibition explaining why not
// (both documents necessarily use the words "contract page" to say "never link one").
const INSTRUCTS_LINKING = [
  /\bOR link the contract\b/i,
  /\blink the contract page\.\s*Record\b/i,
  /\bvs\.? linking the contract page\b/i,
  /\beither state the rate .* OR link\b/i,
  /\bstates the rate or links the contract page\b/i,
];

describe("the runbook never tells the drafter to link a contract or pricing page (#612)", () => {
  it.each(INSTRUCTS_LINKING)("the runbook does not match %s", (pattern) => {
    expect(runbook).not.toMatch(pattern);
  });

  it.each(INSTRUCTS_LINKING)("PLAN.md does not match %s", (pattern) => {
    expect(plan).not.toMatch(pattern);
  });

  // The prohibition itself must be present. Without this, deleting the warning would silently pass:
  // the absence of a bad instruction is not the same as the presence of a good one.
  // Whitespace-tolerant: the runbook is prose that gets rewrapped, and a pattern pinned to one
  // particular line break reports a rule missing when it is still there.
  it("the runbook positively forbids linking a contract, pricing, or rates page", () => {
    expect(runbook).toMatch(/never\s+link\s+to\s+a\s+contract,\s+pricing,\s+or\s+rates\s+page/i);
  });

  // #1906 INVERTED this guard. It used to assert the runbook still told the drafter to state the
  // rate plainly, which was right until Dan reversed the rule on 2026-07-31: "I feel like I'm more
  // likely to get a response if I don't, because they may check out my portfolio instead of getting
  // sticker shock and then email me asking about it."
  //
  // The guard is kept rather than deleted, and pointed the other way, because the failure mode is
  // unchanged in shape: an edit that restores "always state the rate" would put a price back into
  // every cold email with nothing to catch it. Note the prohibition on a pricing PAGE above is a
  // different rule and still stands: the page never existed, which is why linking one invents a 404.
  it("the runbook tells the drafter a cold pitch carries no price and no turnaround", () => {
    expect(runbook).toMatch(/carrying\s+NO\s+PRICE\s+AND\s+NO\s+TURNAROUND/i);
    expect(runbook).not.toMatch(/ALWAYS\s+state\s+the\s+rate\s+plainly/i);
  });

  // #2874 swept the sibling: the same reversal was never carried into PLAN.md, which went on stating
  // "The email always states the rate plainly (#612)" for two weeks after Dan reversed it, one section
  // below the heading the runbook cites as the drafter's own source ("Draft the email (PLAN.md section
  // 7 ...)"). Nothing handed PLAN.md to a run, so no draft was ever written from it, which is exactly
  // why it could sit contradicting the shipped rule unnoticed. The guard above is pointed at PLAN.md too
  // so the pair cannot come apart again in the direction that matters (a price in a first email).
  it("PLAN.md does not tell the drafter to state the rate in a cold pitch", () => {
    expect(plan).not.toMatch(/ALWAYS\s+states?\s+the\s+rate\s+plainly/i);
  });

  // #5 Phase 0: the `variant` field no longer records the retired constant "rate_stated" (a leftover
  // from the killed rate-vs-contract A/B, which the offer bullet above still explains was never real).
  // It now records the opener archetype the drafter actually PRODUCED (one of the four #362 shapes), so
  // Overture can eventually see which openers land. Guard both halves: the dead constant is gone, and
  // the live instruction to echo the produced archetype into `variant` is positively present.
  it("the runbook records the produced opener archetype in `variant`, not the retired constant", () => {
    expect(runbook).not.toMatch(/rate_stated/);
    expect(runbook).toMatch(/record which archetype/i);
    expect(runbook).toMatch(/in the `?variant`? field/i);
  });

  // Proves the check can actually fail, rather than passing because the patterns match nothing at
  // all. The exact sentence that used to sit in the runbook must be caught.
  it("would catch the instruction if it came back", () => {
    const oldText =
      "- **Offer:** held positively. A/B variant, either state the rate plainly ($250 an " +
      "hour plus tax) OR link the contract page. Record which in `variant`.";
    expect(INSTRUCTS_LINKING.some((p) => p.test(oldText))).toBe(true);
  });
});
