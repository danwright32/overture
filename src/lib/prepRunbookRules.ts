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
  // #2382: the third hard disqualify, and it needs three separate guards because dropping any one of
  // its parts puts back a DIFFERENT wrong answer, and each one is a shape a run actually produced on
  // 2026-08-09. Without the first, an agency's shared inbox satisfies step 2 and the pitch goes to a
  // desk that exists for casting people. Without the second, the one legitimate case (the target's own
  // page naming a person at its management) is lost along with the abuse. Without the third, the run
  // spends its remaining lookups hunting the named agent, which is precisely the trade Dan declined.
  { name: "agency-inbox-never-satisfies-step-two",
    pattern: /A third party's generic inbox NEVER satisfies step 2/i },
  { name: "representative-only-when-the-target-names-a-person",
    pattern: /the target's OWN page publishes a\s+NAMED person there as its contact route/i },
  { name: "never-hunt-the-agent", pattern: /do NOT go looking\s+for the agent/i },
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
  // #1887: the two halves of the venue-history rule, and each fails in its own direction.
  //
  // Dropping the NO-COUNT half puts an exact number back in an email about Dan's own history,
  // which is the one thing he was explicit about ("never an exact number"). The app deliberately
  // sends a band and no count, so a number in a draft is always invented.
  //
  // Dropping the ABSENT half is #1824 returning: a prompt that references a field the payload does
  // not carry makes the model supply it. Here that means claiming Dan knows a room he has never
  // worked, to someone who works there.
  { name: "venue-history-never-a-count",
    pattern: /NEVER\s+state\s+a\s+count/i },
  { name: "venue-history-absent-means-silent",
    pattern: /An\s+ABSENT\s+`venueHistory`\s+means\s+SAY\s+NOTHING/i },
  // Dan, 2026-07-31, reading the first real draft this rule produced: "I've photographed a few shows
  // in that room already, so I'm not learning it on the night". The band was right; the clause the
  // model hung off it names the bad outcome and plants it in the reader's head. Drop this and the
  // sentence meant to prove he knows the room starts describing a photographer who might not.
  { name: "venue-history-clause-is-familiarity",
    pattern: /follow-on\s+clause\s+is\s+about\s+FAMILIARITY/i },
  // Dan, 2026-07-31: "the portfolio" reads as a shared company asset in an email written entirely in
  // his own first person.
  // #1906: the rule this REVERSED was stated as mandatory ("ALWAYS state the rate plainly"), so a
  // careless edit restoring the old sentence is entirely plausible. Dan's reason is that a number in
  // a first email from a stranger gets judged before the work does.
  { name: "cold-pitch-carries-no-price",
    pattern: /carrying\s+NO\s+PRICE\s+AND\s+NO\s+TURNAROUND/i },
  { name: "portfolio-is-mine-not-the",
    pattern: /It\s+is\s+MY\s+portfolio,\s+never\s+THE\s+portfolio/i },
  { name: "pursue-each-named-performer", pattern: /pursue EACH named performer directly/i },
  { name: "performer-misidentification-low", pattern: /misidentification\s+risk, so mark it `low`/i },
  { name: "named-performer-never-dropped", pattern: /Dropping a named\s+performer\s+is the failure/i },
  { name: "high-confidence-only-when-read", pattern: /allowed ONLY for an\s+address actually READ from a real page/i },
  { name: "no-pattern-guessed-high", pattern: /NEVER emit a pattern-guessed address/i },
  // #2265: a social profile stopped the waterfall dead on 2 of the 3 shows in the 2026-08-07 run, while
  // a freely published address sat one fetch away. Two rules, and they fail in different directions.
  //
  // Dropping the canonical-domain rule loses the case that was actually measured: search returned
  // Facebook, Apple Music and LinkedIn for the literal string "ryanjamesmonroe.com", so search was
  // never going to reach the site, and one direct fetch did (`ryan@ryanjamesmonroe.com`, 200 on the
  // first try). Dropping the pointer rule lets a DM keep satisfying step 3, which is what made the run
  // stop looking at all.
  { name: "try-the-canonical-domain", pattern: /fetch the canonical guess directly/i },
  { name: "social-profile-is-a-pointer", pattern: /a social profile is a pointer, not a destination/i },
  // #2269: and neither rule means anything if the run reports links it never received. Measured
  // 2026-08-07: it summarised a profile as carrying "and 2 more" links when the fetched page held one.
  { name: "only-what-the-fetch-returned", pattern: /only what the fetch actually returned counts/i },
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
  // #1856: where a listing names no producer, the run pursues the people it DOES name. Without this the
  // run researches an organisation that does not exist and reports that nobody publishes an address, a
  // claim about a search it never ran.
  // #1817: a big bill at a rental room must not collapse back into a search for a company that does not
  // exist. Dan's call, 2026-07-31: pursue every performer the listing names.
  { name: "no-headcount-ceiling-without-an-organiser",
    pattern: /There\s+is\s+NO\s+headcount\s+ceiling\s+here/i },
  // #1817: and where nobody can be named at all, say that, rather than claiming a search that never ran.
  { name: "no-one-identified-is-not-nothing-published",
    pattern: /`no_one_identified`[^\n]*\(#1817\)/i },
  { name: "act-pursued-when-no-organiser-named",
    pattern: /`onlyTheActIsNamed == true`[^\n]*whatever\s+`production`\s+says/i },
  // The other half, and the one that protects Dan rather than the answer rate: the room is the one
  // organisation on those pages that is certainly not the producer.
  //
  // #2259 narrowed this from #1856's blanket ban on `presenter` here. The blanket version was built on a
  // claim the flag never made ("this listing named no producing organisation at all") and closed the only
  // door out of the route: ICB Productions was named twice on the page the run was reading, and the
  // runbook forbade emitting it. What must never be emitted is the ROOM.
  { name: "never-the-room-as-presenter",
    pattern: /NEVER\s+emit\s+the\s+ROOM\s+as\s+`provenance:\s*"presenter"`/i },
  // #2259: and the door that replaced it. Dropping this rule returns the run to being told there is
  // nothing to find on a page that names the producer in its own title line, which is what sent eleven
  // web calls after two individuals and reached Dan as "No email found".
  { name: "the-page-may-name-a-company",
    pattern: /First,\s+find\s+out\s+whether\s+the\s+PAGE\s+names\s+a\s+company/i },
  // #2259: the same run never once searched the company's bare name. Every query fused it to a founder
  // plus three or four keywords, and every one came home with the wrong company; the bare name returned
  // the right one first. Dropping this rule loses a fix that costs nothing and decided the answer.
  { name: "search-the-bare-name-first",
    pattern: /Search\s+the\s+target's\s+BARE\s+NAME\s+first/i },
  // Dan, 2026-07-31, five rules from one review of one real draft. Each one is a live instruction whose
  // removal reverts the draft to a shape he rejected by name, and none of them can be caught by reading
  // the code: the only evidence is the sentence a stranger receives.
  //
  // Dropping this one returns the drafter to reciting the reader's own show back at them. The offending
  // draft opened "Don't Be So Hard on Yourself is 75 minutes of new songs and a cast of five", which was
  // its showSummary pasted in, and the same class had already happened on 2026-07-18 ("An evening of Glee
  // covers ... comes to 54 Below on July 19"). It recurred precisely BECAUSE the 2026-07-18 rule was never
  // written into either source, so this guard exists to stop that happening a third time.
  // Anchored on the rule's TEST rather than its title: "Name the show, describe nothing" is referenced
  // from two other rules as well, so a title-matching pattern survives its own deletion (the guard's
  // negative test caught exactly that) and would report the rule present after it had been removed.
  { name: "name-the-show-describe-nothing",
    pattern: /does this tell the reader something they do not\s+already know about their own night/i },
  // Dropping this restores openers that start talking before saying who is talking. The instruction it
  // replaced actively told the drafter NOT to lead with Dan's name, which nobody had asked for.
  { name: "sentence-one-introduces-dan",
    pattern: /Sentence one always introduces Dan, by name and by trade/i },
  // #2545 INVERTED #393's rule: the app composed the greeting above the body and forbade one inside it,
  // and now composes nothing, so a body that does not greet goes out headless. Three guards, because
  // each half fails differently and each returns a shape the app will actually refuse to send.
  //
  // Without the first, the drafter writes what #393 trained it to write, a body starting at the first
  // real sentence, and every draft in the run is held at Recipient.isBlockedByGreeting.
  { name: "body-opens-with-the-greeting",
    pattern: /The body OPENS with the greeting \(#2545\)/i },
  // Without the second, the drafter does the natural thing on a show with two contacts and writes
  // "Hi Emma and Tom,". The greeting is frozen into the body at draft time and cannot re-address itself
  // when the contact list changes, which is why a named greeting on a shared email is refused outright
  // rather than merely discouraged.
  { name: "several-contacts-get-an-unnamed-hello",
    pattern: /Two or more contacts on the show.*\n?.*with NO name/i },
  // Without the third, #610's routing is lost: a pitch to info@ opens "Hello," with nothing telling
  // whoever reads it which desk it is for. It is the only thing naming a human on those addresses,
  // measured at 16 live contacts on 2026-08-12.
  { name: "attn-line-routes-a-shared-inbox",
    pattern: /routes the pitch to the right desk without pretending/i },
  // Dan works in the CITY, which is a different place from the state.
  { name: "the-city-not-the-state",
    pattern: /never bare "New York"/i },
  // Two halves, and each fails differently. Without the ask, the email states an offer and leaves the
  // next move to a stranger. Without the PRESUPPOSITION, a rewrite turns the ask into a yes/no offer
  // ("would you like coverage?") that invites the no: asking about their photography plans takes for
  // granted that plans exist, so a reader who has not thought about it now assumes they should have.
  { name: "ask-presupposes-photography-plans",
    pattern: /never whether they want photography\s+at all/i },
  // The close expects a reply. Inviting questions makes the reader invent one after the email has already
  // given them the rate, the turnaround and the ask.
  { name: "soft-question-close-retired",
    pattern: /"Happy to answer any questions" is RETIRED/i },
  // Where Dan stands is his problem to solve, not a selling point: a reader who pictures a photographer
  // parked at the back hears "distant" rather than "discreet".
  { name: "effect-not-vantage-point",
    pattern: /Say the EFFECT, not the vantage point/i },
];

/** Returns the names of the rules whose text is absent from the given runbook contents. */
export function findMissingRunbookRules(runbookText: string, rules: RunbookRule[] = RUNBOOK_RULES): string[] {
  return rules.filter((r) => !r.pattern.test(runbookText)).map((r) => r.name);
}
