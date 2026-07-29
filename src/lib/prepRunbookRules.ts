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
  // #1405: the portfolio link must be matched to the show's discipline (music, bands, comedy, dance,
  // and opera/theater to the performing-arts gallery), so the recipient lands on relevant work.
  // Dropping this rule sends every prospect the general site again, the exact regression #1405 closed.
  { name: "discipline-matched-portfolio-link", pattern: /Discipline-matched portfolio link \(#1405\)/i },
];

/** Returns the names of the rules whose text is absent from the given runbook contents. */
export function findMissingRunbookRules(runbookText: string, rules: RunbookRule[] = RUNBOOK_RULES): string[] {
  return rules.filter((r) => !r.pattern.test(runbookText)).map((r) => r.name);
}
