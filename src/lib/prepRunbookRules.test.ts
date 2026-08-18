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
const replyRunbook = readFileSync(join(repoRoot, "docs", "reply-classify-runbook.md"), "utf8");

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
      "body-runs-in-short-paragraphs",
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
      "no-two-sentences-in-a-row-alike",
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
      "rate-answer-add-ons-are-named",
      "rate-answer-add-ons-are-never-priced",
      "rate-answer-full-usage-rights",
      "rate-answer-never-in-a-cold-pitch",
      "rate-answer-no-charge-for-editing",
      "rate-answer-no-hidden-fees",
      "rate-answer-one-hour-minimum",
      "rate-answer-online-gallery-downloads",
      "rate-answer-rate-plus-tax",
      "rate-answer-tax-exempt-pays-no-tax",
      "rate-answer-two-paragraphs-verbatim",
      "rate-answer-two-week-delivery",
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

// #2874, the sibling half. The runbook guarded above is the PREP prompt, which drafts the COLD pitch and
// is forbidden to state a rate at all. The run that actually answers "what do you charge" is a different
// one reading a different prompt (docs/reply-classify-runbook.md), and it is the run whose draft was
// measured on 2026-08-17 stopping at the number. Fixing only the prep runbook would leave the reader that
// caused the defect untouched.
//
// That runbook deliberately does NOT get a third copy of the canonical text: it points at the skill both
// runs invoke, so there is one place the paragraphs live in full and one place they can be edited (L41).
describe("the reply drafter is sent to the canonical rate answer (#2874)", () => {
  it("tells the reply run the rate answer is reproduced verbatim, not summarised", () => {
    expect(replyRunbook).toMatch(/two\s+paragraphs,\s+VERBATIM/i);
  });

  // The sentence that licensed the thin answer, kept as a negative for the same reason "Happy to answer
  // any questions" is: it told the run to include "Dan's standing facts only when relevant (rate,
  // two-week delivery, ...)" while also telling it to keep drafts short, which is an instruction to
  // compress precisely the answer that must not be compressed.
  it("no longer tells the reply run to reduce the rate to a standing fact", () => {
    expect(replyRunbook).not.toMatch(/standing\s+facts\s+only\s+when\s+relevant/i);
  });
});
