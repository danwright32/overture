// Presence guard for the prep-runbook's JUDGMENT rules (#591), the always-on half of the eval harness.
//
// docs/prep-runbook.md is a prompt executed as a headless AI run, not code. Each rule below is a live
// instruction the drafter obeys; deleting one during an unrelated edit silently changes what reaches a
// real prospect, with nothing but Dan's eye to catch it. This asserts each rule stays POSITIVELY present,
// the same technique draftOfferGuard.test.ts (#612) uses for the contract-page prohibition (which is why
// that specific rule is guarded there, not duplicated here). The fixture-based scoring in prepEval.ts
// covers the OUTCOME of these rules on produced drafts; this covers the rule text itself.
//
// Each pattern matches a UNIQUE phrase in the current runbook, so its negative test (delete the phrase,
// expect the guard to report the rule missing) proves the guard discriminates instead of passing
// vacuously against a phrase that was never there.

export interface RunbookRule {
  name: string;
  pattern: RegExp;
}

export const RUNBOOK_RULES: RunbookRule[] = [
  { name: "never-host-venue-target", pattern: /never the host venue \(#366 \/ #368\)/i },
  { name: "venue-address-disqualified", pattern: /belonging to the host venue is DISQUALIFIED/i },
  { name: "press-media-disqualified", pattern: /Never offer a press\/media\/PR address/i },
  // #1722: an entry with no contacts must say WHY. It is the only trace a refusal leaves, since the two
  // disqualify rules above forbid ever emitting the address that was refused. Drop this and every empty
  // answer silently returns to claiming the search found nothing (L11).
  { name: "empty-answer-carries-a-reason", pattern: /ALSO set `emptyReason` on that same entry/i },
  { name: "carnegie-citywide-press-example", pattern: /publicrelations@carnegiehall\.org/i },
  // #1720: the two halves of the house rule, and each fails in its own direction.
  //
  // Dropping the LOOKUP rule puts the judgment back inside the prompt, where it drifts from
  // ProducerGate silently: #1702 centralised it precisely so a second copy could not, and the English
  // version (compare the org's domain against the host venue's) was refuted on five live rows served
  // from carnegiehall.org whose host venue's domain is not.
  //
  // Dropping the VISIT rule is #1681 returning: the run names an organisation, searches for it, and
  // reports that no contact exists without ever fetching its site, which reads to Dan as a completed
  // lookup and is an abandoned one. It is also the expensive direction, since he pays per lookup.
  // Whitespace-tolerant, like the wrapped rules below: the runbook is prose that gets rewrapped, and a
  // pattern that only matches one particular line break reports a rule missing when it is still there.
  { name: "house-list-decides-not-the-run",
    pattern: /never\s+judge\s+for\s+yourself\s+whether\s+an\s+organisation\s+is\s+really\s+the\s+venue/i },
  { name: "named-organisation-must-be-visited",
    pattern: /Naming\s+it\s+in\s+a\s+search\s+query\s+is\s+not\s+visiting\s+it/i },
  // #1723: a house's fuller name. The store spells it "Jalopy Theatre"; its own site says "Jalopy Theatre
  // and School of Music", and an exact lookup misses, so the run reads the house as a pitchable presenter.
  // Measured on the live store: two of the eight verdicts this phase pins failed on exactly this. The
  // whole-words and two-word guards are load-bearing and mirror ProducerGate.containsAsWords: without
  // them "Bard" and "Irondale", both real single-word houses, would swallow every organisation whose name
  // contains those letters.
  { name: "house-name-matches-a-longer-name",
    pattern: /contains\s+a\s+listed\s+house's\s+name\s+as\s+whole\s+words/i },
  { name: "pursue-each-named-performer", pattern: /pursue EACH named performer directly/i },
  { name: "performer-misidentification-low", pattern: /misidentification\s+risk, so mark it `low`/i },
  { name: "named-performer-never-dropped", pattern: /Dropping a named\s+performer\s+is the failure/i },
  { name: "high-confidence-only-when-read", pattern: /allowed ONLY for an\s+address actually READ from a real page/i },
  { name: "no-pattern-guessed-high", pattern: /NEVER emit a pattern-guessed address/i },
  { name: "partial-performer-results-ok", pattern: /Partial results are fine/i },
  // #1597: a grouped item researches one producer and answers for several shows. Two halves must hold,
  // and each fails in a different direction. Dropping the "emit every key" rule silently reverts the
  // whole saving (the run answers one show and Dan is told the rest are unchecked). Dropping the
  // "never invent a grouping" rule is far worse: the run would stamp one contact across unrelated
  // productions, which is the exact permissive failure ProducerGate exists to prevent.
  { name: "grouped-answer-emits-every-key", pattern: /for every key in `alsoAnswersFor`/i },
  { name: "grouped-answer-never-self-invented", pattern: /Never invent an `alsoAnswersFor` grouping yourself/i },
  // #1122: a run whose opening night has passed must be pitched on its remaining dates only, never
  // naming the gone opening. Dropping this rule would let a draft cite a date already behind us.
  { name: "passed-opening-not-named", pattern: /NEVER name or reference the passed opening night/i },
  // #1215: a returning client (booked) or a warm lead (warm) must not be reintroduced cold. Dropping
  // this rule would send a stranger's self-introduction and credential recital to someone who already
  // knows Dan, and would remove the guardrail against inventing a past-project memory to sound warm.
  { name: "returning-client-register", pattern: /a returning-client register does not license invented history/i },
  // #1832: one link in every draft, the site itself, and the reader clicks into whichever portfolio they
  // want (Dan, 2026-07-30). Dropping this rule returns the drafter to picking a gallery per discipline,
  // which is a choice made on the reader's behalf, and the app would then refuse to send what it wrote.
  { name: "one-portfolio-link-never-a-gallery",
    pattern: /One portfolio link, always the site itself/i },
  // #1824: the three halves of "read what the show is", and each fails in its own direction.
  //
  // Dropping the USE rule returns the drafter to the state that produced the Alex Syiek draft: the app
  // renders the listing, the text rides in the queue, and nothing tells the run to read it, so a draft
  // describes a cabaret concert as "intimate, funny material" and names nothing.
  //
  // Dropping the HONEST ABSENCE rule is the more expensive direction, because it fails silently and in
  // Dan's name: with no instruction that "no description published" is a complete answer, a run handed a
  // season calendar (roughly a third of the store's listing URLs) describes this show out of the
  // neighbouring listings, and the invention reads exactly like research.
  //
  // Dropping the SELF-DESCRIPTION rule is what put "working with performing arts organizations in New
  // York" in front of one singer-songwriter. The phrase is in neither this runbook nor the skill; it was
  // built out of Dan's own identity line and applied to a reader who does not fit it.
  { name: "use-the-listing-handed-over",
    pattern: /Before\s+you\s+draft,\s+read\s+what\s+the\s+show\s+IS/i },
  { name: "no-description-is-a-complete-answer",
    pattern: /"No description published"\s+is a correct and complete answer/i },
  { name: "never-categorize-the-recipient",
    pattern: /Describe Dan, never categorize the recipient/i },
];

/** Returns the names of the rules whose text is absent from the given runbook contents. */
export function findMissingRunbookRules(runbookText: string, rules: RunbookRule[] = RUNBOOK_RULES): string[] {
  return rules.filter((r) => !r.pattern.test(runbookText)).map((r) => r.name);
}
