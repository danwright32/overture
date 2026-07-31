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
      "act-pursued-when-no-organiser-named",
      "carnegie-citywide-press-example",
      "empty-answer-carries-a-reason",
      "grouped-answer-emits-every-key",
      "grouped-answer-never-self-invented",
      "high-confidence-only-when-read",
      "house-list-decides-not-the-run",
      "house-name-matches-a-longer-name",
      "named-organisation-must-be-visited",
      "named-performer-never-dropped",
      "never-categorize-the-recipient",
      "never-host-venue-target",
      "no-description-is-a-complete-answer",
      "no-headcount-ceiling-without-an-organiser",
      "no-one-identified-is-not-nothing-published",
      "no-pattern-guessed-high",
      "no-presenter-provenance-without-an-organiser",
      "one-portfolio-link-never-a-gallery",
      "partial-performer-results-ok",
      "passed-opening-not-named",
      "performer-misidentification-low",
      "press-media-disqualified",
      "pursue-each-named-performer",
      "returning-client-register",
      "use-the-listing-handed-over",
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
