import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { opensWithAGreeting } from "./draftGreeting";

// #3555: the TypeScript half of the greeting rule, scored against the SAME committed corpus the Swift
// half runs (L26). `DraftGreetingCasesTests` is the other side of this file, and the Swift predicate is
// the source of truth because it is the one a send actually meets (`Recipient.isBlockedByGreeting`).
const corpus = JSON.parse(
  readFileSync(join(__dirname, "..", "..", "fixtures", "draft-greeting", "cases.json"), "utf8"),
) as { version: number; cases: Array<{ from: string; greets: boolean; body: string }> };

describe("does a drafted body open with a greeting (#2545, #3555)", () => {
  // A corpus that came back empty, or drifted to one side, would pass every case below while proving
  // nothing (L98).
  it("reads the shared corpus, and it exercises both verdicts", () => {
    expect(corpus.cases.length).toBeGreaterThanOrEqual(20);
    expect(corpus.cases.filter((c) => c.greets).length).toBeGreaterThanOrEqual(8);
    expect(corpus.cases.filter((c) => !c.greets).length).toBeGreaterThanOrEqual(8);
  });

  for (const c of corpus.cases) {
    it(`${c.greets ? "greets" : "does not greet"}: ${JSON.stringify(c.body)}`, () => {
      expect(opensWithAGreeting(c.body)).toBe(c.greets);
    });
  }

  it("an absent body greets nobody", () => {
    expect(opensWithAGreeting(undefined)).toBe(false);
  });
});
