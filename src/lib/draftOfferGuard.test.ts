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
  it("the runbook positively forbids linking a contract, pricing, or rates page", () => {
    expect(runbook).toMatch(/never link to a contract, pricing, or rates page/i);
  });

  it("the runbook still tells the drafter to state the rate plainly", () => {
    expect(runbook).toMatch(/state the rate plainly/i);
    expect(runbook).toMatch(/rate_stated/);
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
