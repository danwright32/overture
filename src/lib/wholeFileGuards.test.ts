import { describe, it, expect } from "vitest";
import {
  countOccurrences,
  findingsFor,
  positiveContainsAssertions,
  report,
  sourceBindings,
  unescapeSwift,
} from "./wholeFileGuards";

// #2726: the detector for the whole-file guard signature (L135). It is itself a text matcher, so it gets
// the treatment its own subject needs: tested against what it must FIND and against what it must LEAVE
// ALONE, because a detector that flags the ordinary case gets switched off within a day (L93).

const REAL_SHAPE = `
@Suite("Wiring")
struct WiringTests {
    @Test func theModelCarriesIt() {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        #expect(model.contains("showSummary"))
    }
}
`;

describe("finding a whole-file guard a second occurrence can answer (#2726)", () => {
  it("reads the binding between a variable and the app file it holds", () => {
    expect(sourceBindings(REAL_SHAPE)).toEqual([
      { variable: "model", appPath: "UI/QueueView+Model.swift" },
    ]);
  });

  it("finds the positive assertion and where it is", () => {
    const found = positiveContainsAssertions(REAL_SHAPE);
    expect(found).toHaveLength(1);
    expect(found[0].needle).toBe("showSummary");
    expect(found[0].line).toBe(6);
  });

  it("flags an assertion whose text occurs twice in the file", () => {
    const app = "var showSummary: String? = nil\n// ...\nshowSummary: p.showSummary,\n";
    const findings = findingsFor("WiringTests.swift", REAL_SHAPE, () => app);
    expect(findings).toHaveLength(1);
    expect(findings[0].occurrences).toBe(3);
  });

  it("leaves an assertion whose text occurs once alone", () => {
    const app = "showSummary: p.summary,\n";
    expect(findingsFor("WiringTests.swift", REAL_SHAPE, () => app)).toEqual([]);
  });

  // The half that keeps this usable. A NEGATIVE assertion is correctly whole-file: "this file contains no
  // X" is answered by every occurrence, which is the point of it. Reporting those would bury the real
  // findings under the guards that are working exactly as intended.
  it("ignores a negative assertion entirely", () => {
    const negative = `
        let view = source("Overture/UI/QueueView.swift")
        #expect(!view.contains("showPendingBookingsOnly"))
    `;
    const app = "showPendingBookingsOnly\nshowPendingBookingsOnly\n";
    expect(findingsFor("Guard.swift", negative, () => app)).toEqual([]);
  });

  it("ignores an assertion against a variable that is not a whole app file", () => {
    const scoped = `
        let body = SourceGuardHelper.bodyOfFunction(named: "reachedOutList", in: queueView)!
        #expect(body.contains("ClosedOutDepartureRow("))
    `;
    const app = "ClosedOutDepartureRow(\nClosedOutDepartureRow(\n";
    expect(findingsFor("Guard.swift", scoped, () => app)).toEqual([]);
  });

  it("ignores a file it cannot read rather than reporting it as safe or as at risk", () => {
    expect(findingsFor("WiringTests.swift", REAL_SHAPE, () => null)).toEqual([]);
  });

  // A needle carrying Swift escapes is the case most likely to be silently skipped, and those are the
  // guards most worth checking: an interpolation or a quote inside the searched string.
  it("compares the string the guard actually searches for, not its source spelling", () => {
    expect(unescapeSwift('Text(\\"Debug\\")')).toBe('Text("Debug")');
    const withQuotes = `
        let v = source("Overture/UI/QueueView.swift")
        #expect(v.contains("Text(\\"Debug\\")"))
    `;
    const app = 'Text("Debug")\nText("Debug")\n';
    const findings = findingsFor("Guard.swift", withQuotes, () => app);
    expect(findings).toHaveLength(1);
    expect(findings[0].occurrences).toBe(2);
  });

  it("counts overlapping-free occurrences", () => {
    expect(countOccurrences("aaaa", "aa")).toBe(2);
    expect(countOccurrences("abc", "")).toBe(0);
  });

  it("says plainly what a clean report does and does not prove", () => {
    expect(report([], 172)).toContain("not every way a guard can be vacuous");
  });
});
