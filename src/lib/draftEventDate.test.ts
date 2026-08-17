import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { eventDateVerdict, namedDays } from "./draftEventDate";

// #2864: the TypeScript half of the date rule, scored against the SAME committed corpus the Swift half
// runs (L26). Two implementations of one judgment drift the moment either is touched; the corpus is what
// stops that, and `DraftEventDateCasesTests` is the other side of this file.
const repoRoot = join(__dirname, "..", "..");
const corpus = JSON.parse(
  readFileSync(join(repoRoot, "fixtures", "draft-event-date", "cases.json"), "utf8"),
) as {
  version: number;
  cases: Array<{
    name: string; expect: "ok" | "missing" | "wrong"; today: string;
    performanceDate: string; runEndDate?: string; subject?: string; body: string;
  }>;
};

describe("the date a pitch names (#2864)", () => {
  it("reads the shared corpus", () => {
    expect(corpus.cases.length).toBeGreaterThanOrEqual(20);
  });

  for (const c of corpus.cases) {
    it(`${c.name} -> ${c.expect}`, () => {
      expect(eventDateVerdict({
        subject: c.subject, body: c.body, performanceDate: c.performanceDate,
        runEndDate: c.runEndDate, today: c.today,
      })).toBe(c.expect);
    });
  }

  // The corpus itself has to exercise all three verdicts, or a drift to all-accept would pass every
  // case above while proving nothing.
  it("the corpus exercises all three verdicts", () => {
    const seen = new Set(corpus.cases.map((c) => c.expect));
    expect([...seen].sort()).toEqual(["missing", "ok", "wrong"]);
  });

  // A figure that is not a date must never rescue a draft, which is why this does not hunt for numbers.
  it("does not read a rate, a delivery window or a year as a date", () => {
    expect(namedDays("$250 an hour plus tax, delivered within two weeks, since 2019.", "2026-03-10"))
      .toEqual([]);
  });

  // A day the month does not have is not a date, so a nonsense phrase cannot count as a contradiction.
  it("refuses a day its month does not have", () => {
    expect(namedDays("February 30", "2026-03-10")).toEqual([]);
  });
});
