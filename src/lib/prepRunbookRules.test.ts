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
      "a-method-names-a-route",
      "a-name-match-alone-is-not-enough",
      "act-pursued-when-no-organiser-named",
      "agency-inbox-never-satisfies-step-two",
      "ask-presupposes-photography-plans",
      "attn-line-routes-a-shared-inbox",
      "audience-half-said-once",
      "body-opens-with-the-greeting",
      "carnegie-citywide-press-example",
      "cold-pitch-carries-no-price",
      "date-and-venue-are-evidence",
      "effect-claim-never-quantified",
      "effect-not-vantage-point",
      "empty-answer-carries-a-reason",
      "grouped-answer-emits-every-key",
      "grouped-answer-never-self-invented",
      "high-confidence-only-when-read",
      "house-list-decides-not-the-run",
      "house-name-matches-a-longer-name",
      "name-the-show-describe-nothing",
      "named-organisation-must-be-visited",
      "named-performer-never-dropped",
      "never-categorize-the-recipient",
      "never-host-venue-target",
      "never-hunt-the-agent",
      "never-the-room-as-presenter",
      "no-description-is-a-complete-answer",
      "no-headcount-ceiling-without-an-organiser",
      "no-one-identified-is-not-nothing-published",
      "no-pattern-guessed-high",
      "no-route-found-is-the-honest-method",
      "one-portfolio-link-never-a-gallery",
      "only-what-the-fetch-returned",
      "partial-performer-results-ok",
      "passed-opening-night-never-pitched",
      "passed-opening-not-named",
      "performer-misidentification-low",
      "pitch-names-the-shows-date",
      "portfolio-is-mine-not-the",
      "press-media-disqualified",
      "pursue-each-named-performer",
      "reason-first-names-the-date",
      "representative-only-when-the-target-names-a-person",
      "returning-client-register",
      "search-the-bare-name-first",
      "search-the-platform-for-a-profile",
      "sentence-one-introduces-dan",
      "several-contacts-get-an-unnamed-hello",
      "social-profile-is-a-pointer",
      "soft-question-close-retired",
      "the-city-not-the-state",
      "the-page-may-name-a-company",
      "try-the-canonical-domain",
      "use-the-listing-handed-over",
      "venue-address-disqualified",
      "venue-history-absent-means-silent",
      "venue-history-clause-is-familiarity",
      "venue-history-never-a-count",
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
