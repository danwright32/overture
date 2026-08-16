import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { asksAboutPhotographyPlans } from "./prepEval";

// #2531: the TypeScript half of one shared judgment.
//
// #1889 put a deterministic check behind the runbook rule that a drafted pitch must actually ask for
// something, and it scored PRODUCED output in the eval only. A draft Dan writes or edits by hand never
// passed through it, so a pitch that admires the show and asks for nothing could still be sent. The Swift
// draft lint now carries the same finding, and two implementations in two languages must read one
// committed fixture rather than each holding its own idea of the rule (L26).
//
// `fixtures/draft-ask/cases.json` is that fixture. `DraftAskCasesTests` on the Swift side reads the same
// file and asserts the same verdicts, so the two cannot drift without one of them going red.
interface Case {
  name: string;
  from: string;
  asks: boolean;
  body: string;
}

const fixture = JSON.parse(
  readFileSync(join(__dirname, "..", "..", "fixtures", "draft-ask", "cases.json"), "utf8"),
) as { version: number; cases: Case[] };

describe("the shared ask corpus (#2531)", () => {
  it("is the corpus both languages judge, and is not empty", () => {
    // A fixture that came back empty would pass every case below it, which is the shape where a guard
    // reports hardest on the thing it can see least of (L98).
    expect(fixture.cases.length).toBeGreaterThan(30);
    expect(fixture.cases.some((c) => c.asks)).toBe(true);
    expect(fixture.cases.some((c) => !c.asks)).toBe(true);
  });

  for (const testCase of fixture.cases) {
    it(`${testCase.asks ? "accepts" : "rejects"}: ${testCase.name}`, () => {
      expect(asksAboutPhotographyPlans(testCase.body)).toBe(testCase.asks);
    });
  }
});
