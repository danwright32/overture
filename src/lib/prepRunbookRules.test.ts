import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { RUNBOOK_RULES, findMissingRunbookRules } from "./prepRunbookRules";

// Always-on regression guard for the prep-runbook's JUDGMENT rules (#591). docs/prep-runbook.md is a
// prompt, not code: an edit that drops a rule (never the host venue, never a press inbox, strict
// confidence) has no compiler to catch it, only Dan noticing a bad draft later. Mirrors the model of
// draftOfferGuard.test.ts (#612): each rule below must stay POSITIVELY present in the runbook, and the
// negative test proves the guard actually fails when a rule is removed rather than passing vacuously.

const repoRoot = join(__dirname, "..", "..");
const runbook = readFileSync(join(repoRoot, "docs", "prep-runbook.md"), "utf8");

describe("prep-runbook judgment rules are present (#591)", () => {
  it("the current runbook is missing none of the guarded rules", () => {
    expect(findMissingRunbookRules(runbook, RUNBOOK_RULES)).toEqual([]);
  });

  it("guards the concrete rules this harness cares about", () => {
    expect(RUNBOOK_RULES.map((r) => r.name).sort()).toEqual([
      "carnegie-citywide-press-example",
      "high-confidence-only-when-read",
      "never-host-venue-target",
      "no-pattern-guessed-high",
      "partial-performer-results-ok",
      "performer-misidentification-low",
      "press-media-disqualified",
      "pursue-each-named-performer",
      "venue-address-disqualified",
    ]);
  });

  // The point of a presence guard: it must FAIL when the rule leaves. For each rule, delete the text it
  // matches and confirm the guard reports exactly that rule missing. Without this a guard could pass
  // because its pattern matches nothing at all (the vacuous-pass trap #612's own test warns about).
  for (const rule of RUNBOOK_RULES) {
    it(`catches the removal of: ${rule.name}`, () => {
      const withoutRule = runbook.replace(rule.pattern, "");
      expect(withoutRule).not.toEqual(runbook);
      expect(findMissingRunbookRules(withoutRule, RUNBOOK_RULES)).toContain(rule.name);
    });
  }
});
