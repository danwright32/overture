import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Presence guard for the scout-extract-runbook's sourceUrl rule (#1276). docs/scout-extract-runbook.md is
// a prompt executed as a headless AI run, not code: an edit that drops this rule silently lets the scout
// record a performer signup form (a getfeedback.com "apply to sing" page) as a show's listing link, so Dan
// clicks through to a form to join the choir instead of the concert he is deciding whether to photograph.
// Mirrors prepRunbookRules.test.ts: the rule must stay POSITIVELY present, and the negative test proves the
// guard fails when the rule leaves rather than passing vacuously.

const repoRoot = join(__dirname, "..", "..");
const runbook = readFileSync(join(repoRoot, "docs", "scout-extract-runbook.md"), "utf8");

// Each matches a UNIQUE phrase in the current runbook (line breaks tolerated), so its negative test
// discriminates instead of passing against a phrase that was never there.
const RULES: { name: string; pattern: RegExp }[] = [
  { name: "sourceurl-never-a-signup-form", pattern: /never a registration or\s+sign-up form/i },
  { name: "sourceurl-dciny-concrete-example", pattern: /getfeedback\.com[\s\S]*?dciny\.org\/events\//i },
  // #1469: the run is the ONLY thing that can tell "this page publishes no venue yet" from "I could not
  // open this show's page". Lose this rule and every placeholder row goes back to reading as an unread
  // page, which switches a small source's cancellation detection off for as long as the placeholder is up.
  { name: "venue-not-published-flag", pattern: /set `venueNotPublished: true`/i },
  { name: "venue-not-published-never-for-an-unread-page", pattern: /Never set it for a page you could not\s+reach/i },
  // #1498: the step that was skipped. On 2026-07-23 a run read Jalopy's listings text for the Brooklyn
  // Folk Festival, saw only "downtown Brooklyn, NY", and nulled the venue without following the row's own
  // link, where the detail page names St. Ann & the Holy Trinity Church outright. A city in the listings
  // text is the reason to follow the link, not a substitute for it.
  { name: "city-in-listing-is-not-a-reason-to-skip-the-link", pattern: /only a CITY[\s\S]*?follow the link before/i },
];

describe("scout-extract-runbook sourceUrl rule is present (#1276)", () => {
  it("the current runbook still carries the signup-form guard", () => {
    for (const rule of RULES) {
      expect(rule.pattern.test(runbook), `missing rule: ${rule.name}`).toBe(true);
    }
  });

  // The point of a presence guard: it must FAIL when the rule leaves. Delete the text each matches and
  // confirm the pattern no longer matches (so a future edit that removes the rule turns this test red).
  for (const rule of RULES) {
    it(`catches the removal of: ${rule.name}`, () => {
      const withoutRule = runbook.replace(rule.pattern, "");
      expect(withoutRule).not.toEqual(runbook);
      expect(rule.pattern.test(withoutRule)).toBe(false);
    });
  }
});
