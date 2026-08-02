import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  runbookQueueVersion,
  runbookResultsVersion,
  runbookItemFields,
  swiftQueueVersion,
  swiftResultsSupportedVersion,
  swiftItemFields,
  compareItemFields,
} from "./prepQueueSpec";

// #1908: docs/prep-runbook.md's "Input / output (exact)" section states the PrepQueue version it
// expects and names every item field. Nothing checked that against the code, so it drifted silently:
// #1897 shipped queue v10 with `venueHistory` and the runbook still said version 9 and did not list
// the field at all, while §2 carried the rule that uses it. Found by chance in a later review.
//
// Worse than ordinary doc rot because the runbook IS the prompt (L27): a spec that omits a field the
// payload carries, or names one it does not, is exactly the condition that makes the model supply the
// missing thing itself (#1824's concrete instance). Both numbers sit in plain text on both sides.

const repoRoot = join(__dirname, "..", "..");
const runbook = readFileSync(join(repoRoot, "docs", "prep-runbook.md"), "utf8");
const queueSwift = readFileSync(
  join(repoRoot, "mac", "Overture", "Domain", "PrepQueue.swift"), "utf8");
const resultsSwift = readFileSync(
  join(repoRoot, "mac", "Overture", "Domain", "PrepResults.swift"), "utf8");

describe("the prep runbook's input spec matches the code (#1908)", () => {
  // A parse that finds nothing must never read as agreement. Each extractor is asserted to have
  // actually found something before any comparison is trusted, so a regex that stops matching after
  // an unrelated rewording fails loudly instead of comparing null to null (L1, L11).
  it("finds a version on both sides rather than nothing on both", () => {
    expect(runbookQueueVersion(runbook)).toBeTypeOf("number");
    expect(swiftQueueVersion(queueSwift)).toBeTypeOf("number");
    expect(runbookResultsVersion(runbook)).toBeTypeOf("number");
    expect(swiftResultsSupportedVersion(resultsSwift)).toBeTypeOf("number");
  });

  it("finds the item fields on both sides rather than nothing on both", () => {
    expect(runbookItemFields(runbook).length).toBeGreaterThan(10);
    expect(swiftItemFields(queueSwift).length).toBeGreaterThan(10);
  });

  it("states the PrepQueue version the app actually writes", () => {
    expect(runbookQueueVersion(runbook)).toBe(swiftQueueVersion(queueSwift));
  });

  // The sibling of the same class, and it has already gone wrong once: the runbook's PrepResults
  // number said 5 from v5 onward while real runs wrote v6, corrected only by the v7 bump in #1722.
  it("states the PrepResults version the app actually reads", () => {
    expect(runbookResultsVersion(runbook)).toBe(swiftResultsSupportedVersion(resultsSwift));
  });

  it("names every PrepQueueItem field and no field the payload lacks", () => {
    const diff = compareItemFields(runbookItemFields(runbook), swiftItemFields(queueSwift));
    expect(diff).toEqual({ missingFromRunbook: [], namedButNotInPayload: [] });
  });
});

// The point of a drift guard: it must FAIL when the two sides disagree. Each case below mutates one
// side and confirms the guard reports exactly that disagreement, so none of the checks above can be
// passing vacuously against text they never matched.
describe("the guard catches each way the two sides can drift (#1908)", () => {
  it("catches a runbook still naming the previous queue version", () => {
    const stale = runbook.replace(/`PrepQueue` version `\d+`/, "`PrepQueue` version `9`");
    expect(stale).not.toEqual(runbook);
    expect(runbookQueueVersion(stale)).not.toBe(swiftQueueVersion(queueSwift));
  });

  it("catches a runbook still naming the previous results version", () => {
    const stale = runbook.replace(/`PrepResults` version `\d+`/, "`PrepResults` version `5`");
    expect(stale).not.toEqual(runbook);
    expect(runbookResultsVersion(stale)).not.toBe(swiftResultsSupportedVersion(resultsSwift));
  });

  it("catches a field the payload carries that the runbook never lists", () => {
    const stale = runbook.replace(/,\s*`venueHistory`\)/, ")");
    expect(stale).not.toEqual(runbook);
    expect(compareItemFields(runbookItemFields(stale), swiftItemFields(queueSwift)))
      .toEqual({ missingFromRunbook: ["venueHistory"], namedButNotInPayload: [] });
  });

  it("catches a brand new Swift field nobody added to the runbook", () => {
    const withNewField = queueSwift.replace(
      /(\n    var venueHistory: String\? = nil\n)/, "$1    var rehearsalNote: String? = nil\n");
    expect(withNewField).not.toEqual(queueSwift);
    expect(compareItemFields(runbookItemFields(runbook), swiftItemFields(withNewField)))
      .toEqual({ missingFromRunbook: ["rehearsalNote"], namedButNotInPayload: [] });
  });

  // The direction that made the model invent a field's contents (#1824): the prompt names something
  // the payload does not carry, so the model supplies it.
  it("catches a field the runbook names that the payload does not carry", () => {
    const invented = runbook.replace(/`venueHistory`\)/, "`venueHistory`, `rehearsalNote`)");
    expect(invented).not.toEqual(runbook);
    expect(compareItemFields(runbookItemFields(invented), swiftItemFields(queueSwift)))
      .toEqual({ missingFromRunbook: [], namedButNotInPayload: ["rehearsalNote"] });
  });

  it("reads the field list from the item spec, not from the prose around it", () => {
    // `production`, `reprepMode` and the rest are discussed at length below the list, and the Write
    // bullet names PrepResults' own fields. Neither may leak into what the item spec is held to.
    expect(runbookItemFields(runbook)).not.toContain("emptyReason");
    expect(runbookItemFields(runbook)).not.toContain("contacts");
    expect(runbookItemFields(runbook)).not.toContain("houses");
  });
});
