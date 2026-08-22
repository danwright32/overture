import { describe, it, expect } from "vitest";
import {
  builtNeedleCount,
  codeContainsAssertions,
  countOccurrences,
  findingsFor,
  normalizedCode,
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

  // #2726: the containsCode form, which this tool could not see at all.
  //
  // That blindness is the part worth testing. Converting a guard to containsCode is the natural fix for
  // the comment-satisfies-the-guard case (L103), and while the tool was blind to the result, every such
  // conversion silently REMOVED a guard from the report. A list that shrinks when guards MOVE rather than
  // when they are FIXED reports a clean bill of health for a shrinking population (L98), and it would
  // have made this very change's own zero a measurement of nothing.
  describe("the containsCode form", () => {
    const CODE_SHAPE = `
@Suite("Wiring")
struct WiringTests {
    @Test func theViewPresentsIt() {
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(SourceGuardHelper.containsCode(".sheet(item: $pendingNightDismiss) { pending in", in: queue))
    }
}
`;

    it("sees a containsCode guard, which it used to ignore entirely", () => {
      const found = codeContainsAssertions(CODE_SHAPE);
      expect(found).toHaveLength(1);
      expect(found[0].variable).toBe("queue");
      expect(found[0].needle).toBe(".sheet(item: $pendingNightDismiss) { pending in");
    });

    it("counts a containsCode needle against the code, not the raw file", () => {
      const app = [
        "// .sheet(item: $pendingNightDismiss) { pending in   <- a comment about it",
        ".sheet(item: $pendingNightDismiss) { pending in",
      ].join("\n");
      // Raw, the needle is there twice; as CODE it is there once, which is what containsCode reads. A
      // tool counting the raw file would call this at risk and send somebody to fix a guard that is fine.
      expect(countOccurrences(app, ".sheet(item: $pendingNightDismiss) { pending in")).toBe(2);
      expect(countOccurrences(normalizedCode(app), ".sheet(item: $pendingNightDismiss) { pending in"))
        .toBe(1);
      expect(findingsFor("T.swift", CODE_SHAPE, () => app)).toHaveLength(0);
    });

    it("flags a containsCode needle that really does occur twice in the code", () => {
      const app = [
        ".sheet(item: $pendingNightDismiss) { pending in",
        ".sheet(item: $pendingNightDismiss) { pending in",
      ].join("\n");
      const findings = findingsFor("T.swift", CODE_SHAPE, () => app);
      expect(findings).toHaveLength(1);
      expect(findings[0].occurrences).toBe(2);
    });

    // A needle BUILT at runtime cannot be read statically. It is COUNTED and said out loud rather than
    // passed over, because an exemption nobody can see is how a blind spot becomes a clean bill of health.
    it("counts a built needle instead of quietly exempting it", () => {
      const built = `#expect(SourceGuardHelper.containsCode("a" + suffix, in: queue))`;
      expect(codeContainsAssertions(built)).toHaveLength(0);
      expect(builtNeedleCount(built)).toBe(1);
      expect(builtNeedleCount(CODE_SHAPE)).toBe(0);
    });

    it("states the unanalysable count in the report every run", () => {
      expect(report([], 188, 3)).toContain("not analysable: 3");
      expect(report([], 188, 0)).toContain("not analysable: 0");
    });
  });
});
