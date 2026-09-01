# Prep runbook (Trigger 2)

How the Prep run finds a contact and drafts an email for each kept prospect. The run
is a Claude Code workflow on Dan's Max plan, launched DETACHED by the app's "Prep
kept" button (it never supervises the run). The run reads the work-list, does the
research and drafting, and writes the results file the app ingests for review.

Proven end-to-end on one real prospect (Indianapolis Children's Choir → Emma
Robinson, Marketing & Communications Manager, verified email from the staff page)
before this was codified.

## Input / output (exact)

**Where these files are is decided by the PROMPT, never here (#2764).** Every path below is named as
what the file IS, not as where it lives, and the prompt this run was launched with gives you the actual
path for each one. If anything anywhere appears to tell you a literal path, the prompt wins. Two reasons,
and both of them cost real work when they bite: a Debug run's folder is not the Release one, so a written
path sends a test run at Dan's live data; and a reachability check and a Prep run own separate sets of
these files (see `RunSlot`), so a written path can name the other, still-running run's results and
destroy the drafts it has already paid for.

- **Read:** the WORK-LIST the prompt names
  (`PrepQueue` version `13`: a run-level `houses[]` (see "The queue names the houses" in §1),
  plus `items[]` each with `naturalKey`, `groupName`, `venue`,
  `performanceDate`, `runEndDate`, `discipline`, `sourceListingURL`,
  `possibleMatchName`, `priorRelationship`, `production`, `reprepMode`,
  `openingNightPassed`, `experimentArmInstruction`, `alsoAnswersFor`, `showListing`, `onlyTheActIsNamed`,
  `venueHistory`, `organisationNamedOnListing`, `refusedEmails`, `presenterOnRecord`). `production` is `self` / `agency` / `unknown`; a v1 item omits it
  (treat as `unknown`). `reprepMode` is `draft_only` / `contacts_only`; absent (the normal case
  for a fresh, never-drafted prospect) means do both, exactly as today. See "Re-prep mode" under
  "Per prospect" below for what each value means for that item. `runEndDate` is the run's closing
  night (absent for a single-night show); `openingNightPassed` is `true` only for a run whose
  opening night has already passed while later dates remain (absent otherwise). See "Run dates"
  under the show-date rule below. `experimentArmInstruction` (v5, #5) is the opener archetype this
  item MUST use when it belongs to an active A/B experiment; absent (the normal case, no active
  experiment) means use the normal #362 rotation. See "Opener archetype" in §2 for its precedence.
  `alsoAnswersFor` (v6, #1597) is a list of OTHER `naturalKey`s this one item answers for; absent
  (the normal case) means the item stands alone. See "One answer, several shows" below.
  `houses` (v7, #1720) is RUN-LEVEL, beside `items` rather than inside them, because it is one
  answer about the whole store rather than a fact about any one show: every organisation the app
  has judged to be the building rather than the act, each as a folded `key` and a readable `name`.
  It decides which organisations you refuse and which you must go and visit; §1's "The queue names
  the houses" is the rule, and it applies to every item in the run.
  `showListing` (v8, #1824) is what the show's OWN listing page says, rendered by the APP and handed
  to you as text, because your tools cannot render a JavaScript-drawn page. It carries a `status` of
  `read` (with the page's `text`, plus `truncated` when the page had to be cut at 4000 characters) or
  `unreadable`, and is ABSENT when there was no page to look at. See §2's step on grounding a draft in the
  listing; the three states are three different answers and you say a different thing about each.
  `onlyTheActIsNamed` (v9, #1856) is `true` on a show that reached the app with NO producing organisation
  stored for it: the room it plays in is not the producer, so the app has nobody to hand you as the
  organisation and the act is who you pursue by default. It is a fact about the stored row, NOT a
  statement that the page names no company: on ICB Productions' "Summer Lovin'" the page's own title line
  named the producer twice while this flag was `true` (#2259). Absent is not `false`: it means the app said
  nothing about it (a file predating the field, or a show that names a producer), and you behave exactly as
  you always did. See §1's route for what to do with it.
  `organisationNamedOnListing` (v11, #2259) is the party the show's OWN listing page credits as producing
  it, read by the app off `showListing.text`. Despite the field's name it may be a COMPANY OR A PERSON
  since #2554 (the name is kept because v11 and v12 fixtures are frozen records of what those versions
  were). When it is present, that party is a
  real research target and a legitimate `provenance: "presenter"`, and a `primary` contact, even on an
  item whose `onlyTheActIsNamed` is `true`. ABSENT means only that the app's parse (a possessive credit
  before the title, or an adjacent "produced by" / "presented by" / "produced and directed by" naming
  somebody after it, #2262/#2554) found nothing; it is never a statement that the page names nobody, and
  you still read the text yourself. On a rental room this is the common case: measured across 54 Below's 61 listings on
  2026-08-11, 17 bill a producer and 16 of those name an individual, whom the app's rule does not accept
  as a company and leaves for you. See §1's route.
  `presenterOnRecord` (v13, #2983) is the producing organisation THE APP ALREADY HOLDS for this show, by
  name. It is the same fact `onlyTheActIsNamed` is the flag for, and the two always agree: a name here
  means that flag is `false` or absent, and `onlyTheActIsNamed: true` means there is no name to give you.
  Where it is present **you have been handed the answer to who is producing, and searching for it BY NAME
  is your first move, before anything else on the item.** You were not given it before v13, and the cost
  of that was measured: on a cabaret show credited to a real theatre company, a check spent 22 web calls,
  never searched the company's name once, drifted onto a different production of a similarly titled show
  at another venue, and reported `nothing_published` about a company publishing its address on its own
  contact page. Twelve of twenty three empty answers on the live store were that same failure.
  It may name a COMPANY OR A PERSON, and either is a real research target, a legitimate
  `provenance: "presenter"`, and a `primary` contact, on exactly the terms `organisationNamedOnListing`
  already sets out. It is never the room: the app removes a presenter that is only the venue's own name
  before storing it. The two fields cannot BOTH reach you today, because the app renders a listing page
  only for a show that names no producer, so an item carrying `presenterOnRecord` carries no
  `organisationNamedOnListing`; should that ever change, the page's own credit wins on who is producing
  THIS show and `presenterOnRecord` is still researched alongside it rather than dropped.
  **`nothing_published` is not available to you on an item carrying this field unless you actually searched
  that name**, which is the claim the failure above never tested.
  `refusedEmails` (v12, #2392) is a list of addresses DAN HAS ALREADY STRUCK on this show. Do not
  research them, do not write to them, and do not report them back as contacts. He struck them from the
  card BEFORE this run precisely so it would not spend on them: the case that produced the field was a
  show whose contacts were three personal gmail accounts and the act's own domain, all of which he could
  see were wrong at a glance. If your research turns one of these up, that is not a find; drop it and
  carry on looking, and if it is the only thing you can find, report the show as having no contact rather
  than reporting an address on this list. ABSENT (the normal case) means he has struck nothing here; it is
  not an empty list you need to reason about. The app refuses these addresses again when it reads your
  results, so ignoring this field costs Dan money rather than reaching anybody, which is exactly why it is
  worth honouring.
  `venueHistory` (v10, #1887) is how well Dan already knows the ROOM this show plays in, as one of
  `shot_before` / `a_few` / `regularly`. It is a BAND and carries NO COUNT, deliberately: the app
  holds the number and never sends it, so there is nothing for you to state. ABSENT means say
  nothing about the venue, and it is absent for three different reasons you cannot tell apart and
  must not guess between (no history there, no history imported at all, or a Carnegie show, where
  the tenure credential already covers that exact room). See §2's rule on saying Dan knows the room.
- **Write:** the RESULTS FILE the prompt names
  (`PrepResults` version `11`: `results[]` each with `naturalKey`, `contacts[]`, `draft`, an
  optional `alreadyCoveredNote` (see the already-covered fit-risk flag in §1 below), an
  optional `emptyReason` REQUIRED on any entry whose `contacts` is absent, see "Say WHY an
  entry has no contacts" in §1, and (v8, #1824) an optional `showSummary` with a
  `showSummaryAbsentReason` REQUIRED whenever there is no summary, see §2's step on grounding a
  draft in the listing. This number had said `5` since v5 while real runs wrote v6;
  corrected with the v7 bump in #1722.)
  Each entry in `contacts[]` is one party to email for the performance, carrying a
  `provenance` of `act`, `performer`, or `presenter` (never the host venue), and (v9, #2622)
  a `tier` saying WHO they are to the show, see "Say who the contact is" in §1, and (v10, #2912)
  an optional `nameMatchOnly` saying the only thing tying this route to that party is the NAME,
  see step 3(c) in §1, and (v11, #2895) an optional `performanceCorroborated` saying whether the page
  in `sourceUrl` ties that PERSON to THIS performance, see "Say whether the page you cited
  corroborates the performance" in §1. Emit either
  the act OR its named lead performer(s), never both, see §1 below, plus at most one
  real presenting org; the app sends one separate email per contact. A `provenance:
  "performer"` contact MAY also carry its own `overrideBody`, a direct second-person
  draft for that specific contact (see §2's "Drafting for a performer contact directly"),
  used instead of the shared `draft.body` when the app sends to them. (The legacy v1
  shape carried a single `contact` object; the app still reads it, but new runs MUST
  write `contacts[]`.)
- **Read (optional, #119 voice learning):** the VOICE FEEDBACK file the prompt names (`VoiceFeedback`:
  `pairs[]`, each the AI draft vs. what Dan actually sent). Absent or empty on a fresh
  setup. Skip the learning step when so. See "Once per run" below.
- **Read (optional, #730 cross-run anti-repetition):** the RECENT OPENERS file the prompt names
  (`RecentOpeners`:
  `openers[]`, each the opening SENTENCE a recent draft already used, newest first). Absent
  or empty on a fresh setup. These are shapes to AVOID reusing this run, NEVER a source of
  facts. See §2's anti-repetition rule.
- **Write (optional, #119 voice learning):** the VOICE GUIDANCE file the prompt names: the distilled,
  anonymized voice tendencies, an editable artifact. You regenerate ONLY its
  auto-generated section; Dan's own notes section is preserved untouched.
- **Write incrementally as you go (#1023):** rewrite that same results file with the
  complete `PrepResults` JSON covering EVERY item you have finished so far immediately after
  EACH item, not just at the very end. The launcher script derives the app's live "N of M"
  progress display by counting the entries in this file itself (`PrepProgress` version `1`:
  `{ version, total, completed }`, seeded by the script with `completed: 0` and the correct
  `total`), so the progress count moves forward on its own as this file grows. You do NOT
  write the progress file: asking you to self-report a count is the exact design that left
  scout's counter stuck at 0 through a live run on 2026-07-16 (#1015), so the script owns it
  now. The only thing you must do for progress is keep this results file current after every
  single item.

**The `naturalKey` is an OPAQUE TOKEN.** Copy it from the queue item into the result
byte-for-byte. NEVER rebuild it from group/date/venue: that is the silent-mismatch
trap. The human-readable fields are for research only.

### One answer, several shows (`alsoAnswersFor`, v6, #1597)

When a queue item carries `alsoAnswersFor`, the app has already proved that every key listed there is
a show by the SAME producer, and that this producer is not a room that rents itself out. Research the
contact ONCE, then write that same `contacts[]` into a separate result entry for the item's own
`naturalKey` AND for every key in `alsoAnswersFor`. Copy each key byte-for-byte from the list, exactly
as with the item's own key; never rebuild one and never merge several shows into a single result entry.

Do not re-research per key, and do not skip the extra entries: a reachability check costs real money
per research, and Dan is owed an answer for every show he selected. Emit them all.

The app no longer depends on you doing so (#1804). It wrote the grouping, so when the lead's entry comes
back carrying contacts it applies those contacts to every key in that lead's `alsoAnswersFor` itself, and a
run that emitted one entry settles the same as one that emitted eight. Two things still rest on you. A key
you leave out gets ONLY the lead's contacts, so any research specific to that show (its own summary, its
own refusal) is lost. And the credit is one-directional: a lead that found NOBODY credits nothing, so the
shows it stood for stay unchecked and are paid for again next time. Emitting the entries is still the
cheaper and more accurate path; the app's credit is a net, not a substitute.

Never invent an `alsoAnswersFor` grouping yourself. Two shows sharing a venue, a title, or a
performer are NOT the same producer, and the app is the only thing that may decide this.

Canonical samples of the queue, results, and progress files (the cross-language contract
guard, #157 / #354) live in `fixtures/prep-queue/`, `fixtures/prep-results/`, and
`fixtures/prep-progress/`. Match those shapes exactly; if the format ever changes, update
the fixture and the Swift contract test in the same change.

## Once per run: learn from Dan's recent edits (#119 / #242)

Before drafting anything, fold in how Dan has been revising drafts, so the copy trends
toward send-ready over time. Do this ONCE per run; apply the result to every draft below.

1. **Read the feedback.** Open `overture-voice-feedback.json`. Each `pairs[]` entry holds
   `originalSubject`/`originalBody` (the AI draft) and `sentSubject`/`sentBody` (what Dan
   actually sent), plus `discipline`, `sentAt`, and `outcome` (#245: "booked" / "replied" /
   "no_response" / etc.). A pair may also carry `kind` (#463): `"reply"` is an inbound-reply
   Dan rewrote and sent, absent/`"cold"` is a cold opener. Treat the two registers separately
   (a reply is short and responsive, a cold opener introduces him), and don't carry an
   opener's structure into a reply or vice versa. If the file is absent or `pairs` is empty,
   SKIP this whole section and draft from the skill alone: there is nothing to learn yet (the
   normal state on a fresh setup). Pairs are already ordered winners-first, but weight them
   yourself too: an edit on a `booked` or `replied` email is a stronger lesson than one that
   got no response.

2. **Distill ANONYMIZED tendencies.** For each pair, compare the AI draft against what Dan
   sent and capture the PATTERN of the change, never the content: tone (does he level it
   out, cool it down?), length (does he cut, tighten?), word choice (what he swaps in or
   out, e.g. "cover" → "photograph"), structure (what he drops: throat-clearing,
   over-explaining), punctuation.

   STRIP EVERY SPECIFIC. The bodies carry org names, venues, contact names, production
   titles, prior-relationship facts, and dates. NONE of that is transferable voice, and
   carrying any of it forward is the cross-contamination trap: putting one org's
   "Carnegie Hall" or "I shot your run last spring" into an unrelated email is factually
   wrong and worse than no learning. Write only generalized lessons ("Dan usually cuts the
   second opener sentence", "he replaces warm verbs with plain ones"), NEVER a specific
   ("Dan mentioned Carnegie Hall"). If a tendency can't be stated without a proper noun,
   drop it.

3. **Write the guidance file.** Update `overture-voice-guidance.md`. It has two parts and
   you OWN ONLY THE SECOND:
   - `## Dan's notes (authoritative — never auto-edited)`: NEVER touch this. If the file
     does not exist yet, create it with this heading and an empty body for Dan to fill.
   - `## Observed tendencies (auto-generated; regenerated each run)`: REPLACE this
     section's body with your freshly distilled, anonymized bullets. Keep it SHORT (a
     handful of bullets); prune stale or one-off observations rather than letting it grow.

4. **Apply it when drafting, strictly subordinate.** Precedence, strongest first: the
   `dan-wright-brand-voice` skill (authoritative), then Dan's notes, then the
   auto-observed tendencies (the weakest signal, gentle nudges only). A tendency NEVER
   overrides the skill or Dan's notes and NEVER reintroduces anything the skill forbids
   (e.g. performative enthusiasm). On any conflict, the skill wins.

## Per prospect

### 0. Check `reprepMode` (#367)

Before doing anything else for this item, check its `reprepMode`:

- **`contacts_only`:** this prospect already has a draft Dan does not want touched. Run step 1
  (find the contact) below, but SKIP step 2 (draft the email) entirely: do not emit `draft` on
  the result for this item at all, not even a copy of the existing text. The app treats an
  absent `draft` as "nothing to apply" and will leave the existing draft alone; emitting one
  anyway, even unchanged, risks the app treating it as a real update.
- **`draft_only`:** skip step 1 (finding the contact) entirely for this item: do not emit
  `contacts` on the result. Run step 2 (draft the email) as normal.
- **Absent** (the normal case for a fresh, never-drafted prospect, and also what "re-prep both"
  requests): run both steps as today, unchanged.

This only changes what you emit for THIS item; it has no effect on any other item in the same
run.

### 1. Find the contact (waterfall, PLAN.md §5)

**Who you are reaching: the performing ACT (or, for a self-produced show, its named
lead performer(s)), never the host venue (#366 / #368).** The default target is the
act named in `groupName` (the performers / ensemble / company putting on the show). The
`venue` field is only WHERE the show happens, never who Dan is pitching.

**Decide the target: act, or named performer(s)? (#366 Phase 3)** Check the queue
item's `production` field first:

- **`production == "self"`:** look at the listing/the act's own site for whether it
  names 1-2 individual lead performers (a soloist or duo) as the identifiable face(s)
  of the show.
  - If it does, pursue EACH named performer directly: run the SAME waterfall below once
    per performer, emitting one `contacts[]` entry per performer actually found, with
    `provenance: "performer"` and `name` set to that person. Never emit `act` for this
    show. Each performer entry ALSO gets its own `overrideBody` (see §2's "Drafting for a
    performer contact directly"), since you are emailing them directly, not describing
    them to a third party. A performer NAMED on the authoritative listing is ALWAYS
    surfaced as her own `provenance: "performer"` entry, even when you cannot corroborate
    her against this performance or find a contact for her: in that case still emit a
    contact for her, `provenance: "performer"`, her `name` and `confidence: "low"`, leaving
    `email` and `sourceUrl` absent when you have not verified one.
    **Her `method` is `no_route_found` (#2893).** A `method` names a route, so stating one you
    have not found ("e.g. `form_or_dm`", which is what this rule asked for until 2026-08-17)
    says the search finished when it did not, and a run followed that to the letter on two
    performers, which is what #2893 was filed about. `no_route_found` says what is true: you
    found the person and no way to reach them. The app reads it and reports the show as having
    names and no way to reach any of them. Dropping a named
    performer is the failure; a stale or misnaming secondary source is exactly the case the
    `low` flag exists for, so hold her at low confidence rather than over-trusting the site
    OR omitting her.
  - If the show is a bigger ensemble/group with no clear individual lead (3+ named
    members, or no performer names available at all), fall through to the standard
    single-act waterfall below with `provenance: "act"`, exactly as for a non-self-produced
    show. This is a judgment call from what the listing actually shows, not a hardcoded
    headcount. When genuinely unsure, prefer the act waterfall.
  - Partial results are fine on the CONTACT DETAILS (an email or a corroboration you could
    or could not find), but a performer NAMED on the listing is still surfaced at low
    confidence per above, never dropped for a weak contact; never block trying to find
    every one. Dan reviews every draft and can hand-add anyone genuinely absent from the
    listing via the manual-recipient path.
- **`presenterOnRecord` present (#2983), whatever `production` says:** the app has already told you who
  is producing this show. Search that name FIRST, before the act, before the performers, and before
  anything you might infer from the title: it is the one target on the item you did not have to work out.
  Run the full waterfall below on it, emit it with `provenance: "presenter"` at `primary`, and pursue the
  people named IN ADDITION, never instead. The organisation's own site is the first fetch (its name plus a
  canonical domain guess is one lookup), then its contact page.
  You may not answer `nothing_published` on such an item without having searched that name, and if the
  name led nowhere say so about the search you ran rather than about the show. A search query that merely
  names the organisation is not a visit; the visit rule below applies here in full.
- **`onlyTheActIsNamed == true` (#1856), whatever `production` says:** no producing organisation
  reached the app for this show. The room it plays in is not the producer (the app has
  already removed the room's own name where one was billed), so `groupName` is usually the show's
  TITLE rather than a company, and reporting `nothing_published` after hunting for a company that
  does not exist is a claim you never tested.
  - **First, find out whether the PAGE names a company** (#2259). The flag above is a fact about
    the row the app stored, never about the page. Two things can name one:
    - `organisationNamedOnListing`, when present, IS the party this show's own listing page credits as
      producing it, read by the app off the page. Research it, run the full waterfall below on it, and
      emit it with `provenance: "presenter"`. It is not a guess and it is not the room (the app refuses
      the room's own name here).
      Since #2554 it may name a PERSON as well as a company, because on a rental room the individual
      billed as producing is the one who hired the room and who would hire a photographer, and the app
      used to drop all of them: measured across 54 Below's 61 listings, 17 bill a producer and 16 of
      those name an individual. Research a person the same way you would research a company, starting
      with their own site (the canonical `firstnamelastname.com` guess, which is one fetch and is how
      corinhale.example/contact was there to be found all along).
      **A credited producer is a `primary` contact**, whether person or company: they own the show and
      can say yes. That is the existing tier rule, restated here because this is the field that names
      them, and because the run that missed Corin Hale returned 13 contacts and not one primary.
    - Otherwise read `showListing.text` yourself and look for one: a possessive credit in the title
      line, "presented by" / "produced by", or a bio naming a founder's OWN company ("is the
      Founder/Artistic Director of ICB Productions"). A company you find that way is a legitimate
      `presenter` target too. Be strict about which company: that same text is full of the
      performers' PAST credits, and a company named as somewhere a performer once worked is not who
      is producing this show.
    - A company found either way is pursued IN ADDITION to the people named, never instead of them.
  - Read the item's `showListing.text` for the PEOPLE too. On these shows the app has rendered the
    show's own page for you precisely because the act's name is often nowhere else. Take the
    performer or ensemble names from that text.
  - Pursue EVERY performer the listing names, however many that is, exactly as the
    `production == "self"` route above does: `provenance: "performer"`, one entry per person,
    each with its own `overrideBody`, and each named performer surfaced even where you found no
    contact for her (at `confidence: "low"` with a `method`, per that route's own rule). **There
    is NO headcount ceiling here**, unlike the `self` route above, and the difference is
    deliberate (Dan's call, 2026-07-31): a self-produced show has a real act name in `groupName`
    to fall back on, and one of these does not, so a five-name bill that falls back is a search
    for a company that does not exist. A bigger bill costs proportionally more lookups; that is
    the price of an answer at all here, and Dan chooses whom to write to afterwards.
  - Where you can name NOBODY at all (the listing text is absent or unreadable and `groupName`
    names no findable person or company), do not fall back to a title-shaped organisation search
    and do not report that nobody publishes an address. Return the entry with `contacts` absent
    and `emptyReason: "no_one_identified"`.
  - NEVER emit the ROOM as `provenance: "presenter"` (#2259, replacing #1856's blanket ban on
    `presenter` here). The room is the one organisation on the page that is certainly not the
    producer, and the hard venue-disqualify rule below already forbids it. A company established
    from the page by either route above is a different thing entirely and IS emitted as `presenter`.
    Where no company was established, emit no `presenter` at all: the show's own TITLE is not an
    organisation.
  - If `showListing` is absent or `unreadable`, say so honestly: search on `groupName` alone,
    and where that names nobody findable, `nothing_published` is then a true answer about a
    search you actually ran.
- **`production != "self"`** (agency-produced or unknown) **and no `onlyTheActIsNamed`**: the
  waterfall below runs exactly as it does today, targeting the act with `provenance: "act"`.
  Nothing changes.

**Hard venue-disqualify rule (#368), unchanged regardless of target.** Any address
belonging to the host venue is DISQUALIFIED, not a low-confidence fallback. Treat the
`venue` value as the host: its own inbox and its staff addresses are off the table
entirely. Returning a venue address is a wrong result, not a weak one. Better to return
a form/DM, or no contact at all, than the venue. What counts as the venue is the queue's
`venue` field plus the `houses` list below, never your own reading of who owns the room.

**The queue names the houses; you look them up (#1720).** The queue file carries a run-level
`houses` list: one entry per organisation the app has already judged to be the BUILDING rather
than the act, each with a folded `key` and a readable `name`. To look a name up, either match it
against a `name`, or fold it the same way the keys are folded and match against a `key`. The fold,
in this order: drop everything after the first comma, drop anything inside brackets, put single
spaces either side of any slash, expand a street abbreviation that is the LAST word of what is left
("65th St" becomes "65th Street", while "St Patrick's Church" keeps its "St", because there the
abbreviation is not the last word), collapse any run of spaces to one, lowercase it, then drop a
leading "the". Fold every step or not at all: a half-folded name matches nothing, which looks
exactly like a name that is genuinely not a house. (See also #342, on a curated venue map for the
same question.)

**A house under a longer or shorter name (#1723).** A house often publishes itself under a fuller name
than the one the list carries. Treat a name as that house when, after folding both, either one
contains a listed house's name as whole words. "Jalopy Theatre and School of Music" read on a page is
the listed "jalopy theatre"; "Weill Recital Hall" is the listed "carnegie hall" when the list carries
the hall. Two guards on this, and both matter: whole WORDS only, so a name is never matched on a
fragment inside a longer word, and never match on a house whose name is a single word, because "Bard"
and "Irondale" are both real houses on this list and a bare substring test would read any
organisation containing those letters as the building. A single-word house matches only exactly.

This list is the app's own answer and it is the ONLY house test you have. Its verdicts come from
the same rule the rest of Overture uses, including corrections Dan has made by hand, so you must
**never judge for yourself whether an organisation is really the venue**. Never infer it from a
shared domain, a shared address, a shared name, or a page saying that one runs the other. Those
inferences are wrong on real shows: several organisations here serve their listings from a
house's own domain while playing rooms that house does not own.

- **On the list:** it is the house. Its addresses are DISQUALIFIED exactly as the show's own
  `venue` is, under the hard venue-disqualify rule above.
- **NOT on the list:** it is a lead, and you must VISIT it at its own site before you may conclude
  that no contact exists for this show. Run the waterfall there like any other target.
  **Naming it in a search query is not visiting it.** Reading about it on the host venue's page
  is not visiting it either. An organisation named for this show and never fetched is an
  unfinished lookup, not an empty answer, and must never be reported as one.

An organisation can both own the room and have made the work, and those are two different things. If
the app has not named it a house, it is a presenter and you pitch it, however much the page reads
like the building talking about itself.

If `houses` is ABSENT from the queue file (one written before this list existed), fall back to the
`venue` field alone as the hard rule above describes. An EMPTY list means something different: the
app looked and named no houses, so nothing is disqualified by this rule and every organisation you
find is a lead to visit.

**Hard press/media-disqualify rule (#635), unchanged regardless of target.** Any
address that reads as a press/media/PR contact (e.g. `publicrelations@`, `press@`,
`media@`, or a staff-page listing under a "Media" or "Press" heading) is DISQUALIFIED,
for the SAME reason the venue is disqualified above: it is the wrong department to
pitch photography to, not a low-confidence version of the right one. This applies no
matter whose domain the press inbox sits on, whether that is the venue's (e.g.
`publicrelations@carnegiehall.org` for a show at Carnegie Hall, also caught by the
venue rule above), the act's, or the presenter's. Never offer a press/media/PR address
as a contact at any confidence level; fall through to the next waterfall step
(contact form/DM) instead, or omit the contact entirely if nothing else is found.

**Hard third-party-representative rule (#2382), unchanged regardless of target.** An address
belonging to somebody who REPRESENTS the target (a talent agency, a management company, a
publicist, a booking agency) is not the target's address, and is DISQUALIFIED for the same reason
the venue's and the press desk's are: it is a wrong result, not a weak one. Four parts, and they
are what a run has to ask itself, in this order:

1. **A third party's generic inbox NEVER satisfies step 2.** Step 2 below means an inbox the TARGET
   ITSELF publishes as its own. An agency's `info@` belongs to the agency, whatever the relationship,
   and a shared inbox serving a national agency's offices exists so casting people can hire its
   roster. It will not reach a performer about one night of a cabaret series.
2. **A representative's address is usable in exactly one case:** the target's OWN page publishes a
   NAMED person there as its contact route (e.g. a bio page reading "Representation: Jane Example,
   jane@examplemanagement.example"). That is an address read off the target's own page, so it is
   emitted like any other, with `sourceUrl` set to that page.
3. **Where the target's own page names an agency but publishes no person there, do NOT go looking
   for the agent.** Fall straight to step 3 below (the target's own form or DM), or omit the target.
   Dan's call, 2026-08-09, choosing this over chasing the named agent: the extra lookups are not
   worth what they find.
4. **A representation claim read from a search summary, a social bio tag, or an aggregator is not
   established at all**, so it cannot even reach part 2. Same STRICT verification bar as everywhere
   else: only what a fetch actually returned counts (#2269). On 2026-08-09 a run reached an agency's
   shared inbox for a performer on the strength of an Instagram tag plus a search snippet whose top
   result was a different person with a similar name.

**A site you find may belong to the venue, not the act.** If a page resolves to the host venue's
site, do NOT harvest a contact from it; find the act's (or the named performer's) OWN
site. Landing on the venue's staff page is exactly the bug this rule prevents. (This used to be
written about a `websiteURL` field on the show. That field was deleted in #1640: nothing ever
populated it, so the rule was phrased around a value the run never received. The rule itself stands
and applies to any page the run opens.)

**Search the target's BARE NAME first (#2259).** Whatever the target is, the FIRST query is its name
and nothing else. Only if that comes back with nothing useful do you narrow, and then in this order:
the name plus the venue, then the name plus the city. NEVER open with the name fused to a person plus
several keywords.

This is measured, not a style preference. On 2026-08-07 a run made eleven web calls for ICB
Productions' "Summer Lovin'" and never once searched `ICB Productions` on its own. Both queries that
mentioned the company buried it inside a founder's name plus three or four extra words, and both came
home with the wrong company: a Norwegian firm, an unrelated account, a directory listing, a retail
chain. The bare name returned the right company as the FIRST result, and its address was two clicks
further on. Extra keywords do not sharpen a search for a small organisation; they push a 773-follower
local company below every large one that shares part of its name.

**The waterfall.** Run this once for the act, or once per named performer when pursuing
performers individually (the target below is whichever of those this run is for). Walk
in order, stop at the first that works:

1. **The target's named decision-maker / direct email.** For the act, whoever owns its
   photography/marketing, read off its own staff/contact page. For a named performer,
   their own published email, read off their own site/bio/contact page.
2. **The target's generic inbox** (info@, the ensemble's published address; a solo
   performer rarely has one of these), never a press/media/PR inbox, see the hard
   press/media-disqualify rule above, and never a third party's, see the hard
   third-party-representative rule above. A real email for the target, even a generic one,
   is PREFERRED over a contact form.

   **A named contact behind a generic inbox (#610).** While reading the target's own site for
   this step, you may also come across a specific individual (e.g. a PR associate director, an
   administrative director) named on a staff or press page. If so, ALSO set `name` (and `role`
   when the page states one) on this `generic_inbox` contact, so the app can address the pitch
   to a specific desk instead of a shared one. Same STRICT verification bar as elsewhere: only
   an explicit name actually read from a real page counts, never inferred or pattern-guessed.
   This never changes the contact's `method` or `confidence` (still `generic_inbox` / `medium`)
   and never applies to a `form_or_dm` contact.
   **Before you settle for a form or a DM, two more cheap moves (#2265).** Both were measured on the
   2026-08-07 run, where 2 of 3 shows reported "no email" while a freely published address sat one
   fetch away.

   **(a) A profile is not where the search stops.** Reaching an Instagram, Facebook or X profile is
   the middle of step 3, not the end of it. If the page you fetched carries an outbound link to the
   target's own site, or to a link hub (Linktree, Beacons, Carrd, Milkshake), OPEN it and run steps 1
   and 2 there. That is where a small independent act publishes its address, you have already paid for
   the fetch that revealed the link, and an address Dan can write to beats a DM he has to send by hand.

   **And when that comes back with nothing, the profile itself is the answer, and you emit it (#2612).**
   Dan DMs an act on Instagram by hand, so a handle is a route rather than a dead end: report it as a
   `form_or_dm` contact with the profile URL in `formUrl`. What you must never do is find a profile,
   fail to get past it, and then report `nothing_published`: that says this show's people publish no
   address anywhere, which is a claim about a search you did not finish (L11). On 2026-08-13 that
   happened to Song & Word, whose Instagram Dan found himself in seconds, and the card told him to give
   up on a show he called a perfect fit.

   **(b) When search has not surfaced the target's own site, fetch the canonical guess directly**,
   once: `firstnamelastname.com` for a person, the organisation's name for an organisation. Search is
   not a reliable route to a small act's own site: on 2026-08-07 the literal string
   `"devinmarlowe.example"` was searched and returned Facebook, Apple Music, SoundCloud and LinkedIn,
   while one direct fetch of that domain returned the site and its published address.

   This does NOT relax the strict verification rule. An address READ off a page a fetch returned is
   read, so it qualifies as `high` with `sourceUrl` set. A guessed DOMAIN is not a guessed ADDRESS:
   the domain is verified the moment it resolves and the page identifies the right target. If it does
   not resolve, or the page is somebody else, that is the end of it, and you record nothing.

   **And only what the fetch actually returned counts.** Describe links, addresses and pages from the
   bytes you received, never from what such a page would usually show a person. On 2026-08-07 a run
   reported a profile carrying "and 2 more" links when the page it was given held exactly one; that is
   a fabricated observation, and every rule above is worthless on top of one (#2269).

   **(c) When neither an address nor the target's own site has turned up, GO AND SEARCH the platform
   for a profile (#2892).** Every other social instruction here is conditional on having already landed
   on a profile while reading somebody's site, and (b) only guesses at a domain. Nothing sends you
   LOOKING for a handle, so for the show whose only route is a DM the route was the one thing this
   procedure could not reach, and that is not a rare shape: it is every self-produced act with no
   website.

   Search the platform by name, scoped to the site: `site:instagram.com "<name>"` first, then the name
   plus the show title or the venue. **At most two searches per target**, because the per-item web-call
   cap is 15 and a two-performer show has usually spent most of it by the time it arrives here: on
   2026-08-17 a run spent 12 searches and 3 fetches across two people and finished with nothing.

   **Verify the profile is the right person before you emit it, and a name match alone is NOT enough.**
   Two ordinary names plus a handle resembling neither is precisely the state where a wrong profile gets
   emitted with confidence. The bio or a recent post must carry something tying the account to THIS
   show: its title, the venue, the date, or another name credited on the bill. On a verified hit, emit
   `method: "form_or_dm"` with the profile URL in `formUrl`.

   **On a NAME MATCH and nothing more, emit it and SAY that is all you have (#2912).** Same
   `method: "form_or_dm"` and the profile URL in `formUrl`, `confidence: "low"`, and
   `nameMatchOnly: true`. Dan's call, 2026-08-17: he would rather look at a handle for two seconds and
   judge it himself than never see it, and the search that found it is one nobody repeats cheaply. The
   app treats a contact carrying that flag as a LEAD and not a route: it never counts towards the show
   being reachable, it cannot be stored as verified, and the card prints the handle under a line saying
   the name matched and nothing tied it to this show. What #2147 refuses is intact and is what
   `nameMatchOnly` exists to say: an unidentified target is never presented AS the act. So the flag is
   not optional politeness. Emitting one of these without it is the substitution that rule forbids, and
   the run has already claimed the verification a bare `form_or_dm` carries.

   **Below a name match, still emit nothing.** A handle that is not even the right name is the nearest
   candidate rather than the target, and a wrong handle is worse than none, because Dan sends the DM by
   hand believing it is the act. Let the empty reason say what happened.

   A handle is rarely guessable and rarely searchable. On 2026-08-17 the two profiles for "A Time To Be"
   at The Green Room 42 used a middle name the listing never states and a longer form of a first name,
   so no `firstnamelastname` guess reached either and no plain web search surfaced them. The run
   reported "no verifiable email, site, or social profile" after running the full waterfall, which read
   as a finished search and was not one: the waterfall it ran had no platform search in it. Dan found
   both himself, on the platform, in seconds.

3. **The target's contact form / Instagram DM** when it publishes no email, and only after (a) and
   (b) above have come back with nothing. Record it as `method: "form_or_dm"` with the form URL in
   `formUrl` (the app surfaces it as a tappable link). This outranks any venue inbox.

   **A `method` NAMES A ROUTE, so it may never be emitted without one (#2893).** `form_or_dm` with no
   `formUrl`, or `named_decision_maker` or `generic_inbox` with no `email`, promises a way in and
   supplies none. Use `method: "no_route_found"` instead, keeping whatever you did establish: that says
   honestly that you found the person and not a route, where naming a route you do not carry says the
   search finished when it did not, and the app cannot tell those apart from the entry alone. This
   never means dropping somebody: a named performer is always surfaced, with `no_route_found`, per the
   performer rule above. The field being OPTIONAL in the app's own
   Swift is not permission for that combination: `formUrl` is optional because the two other methods
   have no form, and `email` is optional because a `form_or_dm` contact has no address. On 2026-08-17 a
   run read that source mid-run, concluded "`formUrl` is optional, so a `form_or_dm` contact can carry
   no `formUrl`", and emitted two such contacts; the app discarded both and the card told Dan the show
   had no way in while he found one himself in seconds.
4. **A genuine presenting org** (the presenter named for the show, NOT the venue). You may not have to
   FIND it: `presenterOnRecord` (v13) names it outright where the app already holds it, and
   `organisationNamedOnListing` (v11) where the page credits one. Where either is present this step starts
   from that name rather than from a search for who the producer might be. Find its
   contact the SAME way, running steps 1-3 above once more with the presenting org itself as
   the target (so it too can carry a named decision-maker, a generic inbox with a named
   contact behind it per #610, or a form/DM). Emit the presenter as an ADDITIONAL entry in
   `contacts[]` with `provenance: "presenter"`, alongside the act or performer entries, when
   you find a real presenting org for the show. At most one presenter, and never the host
   venue. This step is unchanged and still runs regardless of `production`; the presenter is
   always additive, never a
   fallback for a missing act/performer contact.

Each contact you emit becomes its own entry in `contacts[]` with its own `provenance`. If
none of the above yields a non-venue contact for a given target, omit that target from
`contacts[]` rather than reaching for the venue (if that leaves nothing at all, return the
result with the key echoed and `contacts` absent).

**Say WHY an entry has no contacts (#1722).** Whenever you return a result with `contacts`
absent, ALSO set `emptyReason` on that same entry to exactly one of:

- `only_venue_contact`: you found an address for this show, and the only one(s) you found
  belonged to the host venue, so the hard venue-disqualify rule refused it.
- `only_press_contact`: you found an address, and the only one(s) you found were a
  press/media/PR desk, so the hard press-disqualify rule refused it.
- `nothing_published`: you looked and this show's act, performers and presenter publish no
  usable address anywhere you could reach. Only honest once you have actually fetched every
  organisation named for this show that is not on `houses`, AND you had someone to look for in
  the first place; until then the lookup is unfinished and this token would claim more than you
  measured. A REPRESENTATIVE is not one of those organisations (#2382): the rule above forbids
  pursuing an agency or management company, so never having fetched one cannot make this token
  dishonest, and its shared inbox is not an address the target publishes.
- `no_one_identified` (#1817): you could not work out WHO to write to. No producing organisation
  was named, and no performer could be named either, so no search for an address ever really
  ran. This is NOT `nothing_published`: that one says the people were found and publish nothing,
  and saying it here claims a search you never made.

This is the ONLY trace a refusal leaves, because the rules above tell you never to emit a
venue or press address at any confidence. Without it the app cannot tell a check that found
the room's own inbox and correctly refused it from one that found nothing at all, and Dan's
card says "No email found" in both cases, which claims the search came up empty when it came
up with something. Report what you actually measured. If you genuinely cannot tell which of
these applies, omit `emptyReason` rather than guessing: the card then falls back to the
plain "no email found" wording, which is the honest thing to say when the reason is unknown.

**STRICT verification (Dan's rule).** `confidence: "high"` is allowed ONLY for an
address actually READ from a real page; set `sourceUrl` to that page's URL (v6, #363:
the app links the confidence badge to it so Dan can verify it himself, distinct from
`formUrl`, which stays reserved for a `form_or_dm` contact's own submission link and
never doubles as a citation). NEVER emit a pattern-guessed address (e.g. firstname@org)
as high; if you only inferred it, use `low` and say so, and omit `sourceUrl` (only
ever meaningful at `high`). Confidence mapping: named+read = high, generic inbox =
medium, form/DM or inferred = low. **For a named performer specifically**, only use
`high` if the source page corroborates that person against THIS SPECIFIC performance
(name plus instrument/role/context match, e.g. their own site lists this date/venue or
names this group); a bare name match with no such corroboration is a misidentification
risk, so mark it `low` instead, same as any other unverified guess.

**Say whether the page you cited corroborates the performance (`performanceCorroborated`, v11,
#2895; every provenance since #3376).** On ANY contact you are emitting at `high` with a `sourceUrl`,
add `performanceCorroborated: true` when that page ties THAT PARTY to THIS performance (it lists this
date or venue, names this group, credits them on this bill, or, for an organisation, presents this
show), and `performanceCorroborated: false` when it does not. It is the rule directly above, said out
loud, so the app can hold the claim down instead of taking it on trust.

**#3376: this is what makes the canonical domain guess safe, and it is why the field is no longer a
performer's alone.** The instruction above tells you to reach an organisation's own site by its name
plus a guessed domain. Names are not unique and a site carries no field saying which bearer of a name
it belongs to, so that step can land on a stranger who shares the name, and the address on such a page
is perfectly real. A blank reads as missing; a wrong address reads as an answer, and the next thing
that happens to it is a pitch under Dan's name to somebody who has nothing to do with the show. So a
guessed domain is a candidate until the page itself ties the party to this show. If it does not, that
is not a failure and not a reason to emit nothing: emit at `low` with
`performanceCorroborated: false`, exactly as the paragraph below already says.

The live case, 2026-08-17: a run emitted a named performer at `high` as `Playwright`, citing their own
portfolio site. That page describes them as "an actor and writer", contains the word "playwright"
exactly once inside the NAME OF A THEATRE in an unrelated regional credit, and never mentions this
show, this venue or this festival. The address really was on the page, so every check that asks about
the ADDRESS passed it. The claim happened to be true, from a source the run never read, which is a
correct conclusion with the wrong evidence behind it on a route that would have recorded an incorrect
one identically. The next thing that happens to such a contact is a pitch under Dan's name addressing a
stranger by a role Overture asserted.

A page you cannot corroborate against is not a failure and is not a reason to emit nothing: emit the
contact with `confidence: "low"` and `performanceCorroborated: false`, exactly as the rule above already
says. Saying nothing is also allowed and is what an older run did, so it changes nothing, but it means
the check cannot help you.

**`confidence` and `nameMatchOnly` (v10, #2912) answer two different questions, and only one of them
is about the PERSON.** `confidence` says how good the ROUTE is, and it is close to mechanical: a form
or a DM is `low` whether or not anybody established whose it is, so it cannot carry "I could not tell
who this is". `nameMatchOnly` is the field that says that, and it is never a substitute for a low
confidence: a contact carrying it is `low` too. Never emit it with `high`, which is a contradiction the
app refuses on your behalf by storing the contact as `low` anyway.

**Say who the contact is (`tier`, v9, #2622).** Every entry in `contacts[]` carries a `tier`. It answers
one question, and it is NOT about billing order: **who could actually say yes to hiring a photographer?**

- `"primary"`: whoever owns the show and could hire Dan. A self-producing headliner (the show is theirs),
  or the producing organisation's producer, artistic director or founder.
- `"secondary"`: somebody ON the show without that authority. A co-performer, a music director, a special
  guest, a host.
- `"tertiary"`: a third party REPRESENTING them. A manager, an agent, a publicist, a booking agency.

Judge it from the page you actually read, the same bar as everything else here, and say what that page
supports rather than what a role title suggests: a music director who also produces the night is primary,
and one who was hired for it is secondary. The app deliberately does not derive this from the `role` text,
because a role is unbounded free text and cannot tell those two apart; you have the page and it does not.

If the page does not support any of the three, OMIT the field. An absent tier reads as "nobody has said",
which is honest, and it scores exactly what a found address has always scored. A guessed tier is worse
than none: `primary` moves a show up into what Dan looks at first, and `tertiary` moves it down.

**Already-covered fit-risk flag (#611).** While reading the act/presenter's own site for the
waterfall above, also watch for an EXPLICIT statement that they already have their own
photographer (e.g. the site names a "Photographer in Residence," a "House Photographer," or
similar wording in words, not just a photo credit). If you find one, set `alreadyCoveredNote`
on the result to a short quote or paraphrase of what the site says (one sentence is enough).
Same STRICT verification bar as above: only an explicit statement actually read on a real page
counts, never inferred from an uncredited photo or a guess. This never changes the fit score or
tier, and never blocks finding a contact or drafting the email below; it only adds a warning the
app surfaces to Dan so he can judge it himself.

### 2. Draft the email (PLAN.md §7 + the dan-wright-brand-voice skill)

INVOKE the `dan-wright-brand-voice` skill and follow it. Then, as secondary nudges only,
apply the distilled voice guidance from "Once per run" above (the skill always wins).

**Before you draft, read what the show IS (#1824).** Not so you can tell the reader (they know, see
"Name the show, describe nothing" below), but so the draft cannot get their show WRONG and so Dan
gets a note on the row saying what you found. Nothing used to tell you: `sourceListingURL` was handed
over and never mentioned again, and on 2026-07-30 one singer-songwriter's cabaret concert was pitched
as if the reader were an organisation.

You cannot open that page yourself: it is drawn by JavaScript and your tools cannot render it (the
same run fetched the URL, got an 11KB shell, asked for a browser and was refused). So the app renders
it for you and hands over the text in the item's `showListing`. Three states, and they are three
different answers:

- **`status: "read"`.** `text` is that page's readable text. Read it FIRST, and let it settle who and
  what you are writing about: the correct show title, who is performing, whether this is one artist or
  a company, whether the page names a producer at all. Use only what the page actually says, exactly
  the grounding discipline that applies everywhere else here. What you read NEVER becomes a
  description in the email; it keeps the email from being wrong, and it fills `showSummary` for Dan.
  If `truncated` is `true`, the page was cut at 4000 characters and what you hold may not be all of it.
- **`status: "unreadable"`.** The app could not read that page. You do not know what this show is
  beyond the queue's own fields. Do not go hunting for the page, and do not infer the show from its
  title: "Don't Be So Hard on Yourself" tells you nothing about what happens on stage.
- **absent.** There was no listing page to read at all.

**A listing URL is often not this show's own page.** Roughly a third of them point at a season
calendar or an index (`/opportunities/`, `/show-schedule.html`, `/calendar-events/`). If the text you
were handed does not describe THIS show on THIS date, that is a page that published no description of
it, NOT a licence to describe this show from the neighbouring listings. **"No description published"
is a correct and complete answer**, and an empty `showSummary` with a reason is far better than one
that says something invented. The email is unaffected either way: it never describes the show.

**Record what you found**, on this item's result entry, so the answer leaves a trace instead of living
only in your head:

- `showSummary`: one plain line saying what this show is, in your own words but sourced entirely from
  the page ("A cabaret concert of new songs by one songwriter, with a cast of five, 75 minutes").
  **This is a note Overture shows DAN on the queue row, and it is not email copy.** Never lift it, or
  any part of it, into the draft.
- When there is no summary to write, LEAVE `showSummary` OUT and set `showSummaryAbsentReason` to
  exactly one of `no_listing_page` (the item carried no `showListing`), `page_unreadable`
  (`status: "unreadable"`), or `no_description_published` (the page was read and does not describe
  this show, the calendar case above included). Never write a summary you could not source.

Anatomy:

- **Relationship register: read `priorRelationship` first (#1215).** The handoff's
  `priorRelationship` is already the confirmation-gated value (`priorRelationshipForDrafting`,
  #752), so act on it directly and never re-derive it. It decides who you are writing to, and
  most of the anatomy below (the opener archetypes, the credential + portfolio scaffolding) is
  the COLD register:
  - `booked` (Dan has actually shot for them, a returning client): write to someone who ALREADY
    KNOWS his work. Skip the cold self-introduction ("My name is Dan and I'm a professional arts
    photographer") AND the credential + portfolio scaffolding below; they need neither. Open warm
    and familiar, reference the specific upcoming show, and go straight to the offer.
  - `warm` (a warm lead or connection Dan has NOT shot for yet): drop the cold self-introduction
    and write in a warmer, more familiar register, but since they have not seen his work FOR them,
    still keep ONE light credential and the portfolio link (below) as soft proof.
  - anything else (`none`, `contacted`, `declined_by_you`, `lost_soft`, `lost_hard`): the cold
    pitch is unchanged, exactly as the rest of this section describes.

  Across all three, warm the TONE only. NEVER fabricate a specific past-project claim ("loved
  shooting your Spring Concert") unless it is actually known:
  **a returning-client register does not license invented history**. The greeting rule below still
  applies in every register.

- **Describe Dan, never categorize the recipient (#1824).** The 2026-07-30 draft opened "I'm a
  documentary photographer working with performing arts organizations in New York" to ONE
  singer-songwriter. That phrase is in neither this runbook nor the skill; it was built out of Dan's
  own identity line and then applied to the reader, who does not fit it. Nothing about introducing
  Dan requires a claim about who is reading, so make none: say who he is and what HE does ("My name is
  Dan and I'm a professional arts photographer here in NYC", "I'm Dan Wright, a documentary photographer
  here in NYC", see the sentence-one rule below) and let the next sentence name THIS show. Never open with a category the reader has to fit ("performing arts organizations",
  "companies like yours", "arts institutions"), and never call a recipient an organisation, a company,
  an institution, a team or an ensemble unless the work-list or the listing actually says so. A solo
  artist, a duo, and a producing company all get the same self-introduction.
- **Name the show, describe nothing (Dan, 2026-07-31).** The reader booked, produced, or performs
  this show. They know what it is. NAME it, with its date and venue, and say why Dan is writing:
  "your August 3 show at The Green Room 42". That is the entire reference to their event.
  **Never write a clause whose job is to say what the show IS**: not its running time, its cast size,
  its theme or premise, its genre or billing, its guest artists, or a quoted review. Not as the
  opening sentence, not buried later, not folded into a sentence about Dan. The test is one question,
  asked of every clause that touches their event: does this tell the reader something they do not
  already know about their own night? If not, cut it. Two real failures, the same class twice:
  - 2026-07-31, this show: "Don't Be So Hard on Yourself is 75 minutes of new songs and a cast of
    five, built around the idea that we're our own harshest critics." Dan: "it literally just
    summarized the show. that person obviously knows what the show is about."
  - 2026-07-18, a 54 Below night: "An evening of Glee covers sung by Broadway performers comes to
    54 Below on July 19." Dan called that email terrible, the first sentence especially.

  Reciting someone's own event back to them in press-release phrasing tells them nothing and reads
  exactly like a line generated from a scraped calendar listing, which is the one impression a
  researched pitch cannot afford. The date and venue are EVIDENCE Dan looked, not an announcement:
  fold them into his reason for writing, never narrate the event. What fills the space instead is
  the half the reader does not know: what Dan does, how he shoots, the credential, the rate, the ask.
- **The body OPENS with the greeting (#2545).** This rule REPLACES #393's "no greeting in the
  body", which said the opposite. Overture used to compose a greeting above the body at send;
  it no longer composes anything at all, so a `body` that does not open with a greeting is a
  wrong result and Overture will refuse to send it.

  Write the greeting as the first line, then a blank line, then the first real sentence. Which
  greeting depends on WHO the email reaches, and there are exactly three cases:

  1. **One named contact.** `Hi <first name>,` on its own line. "Hi Emma," then a blank line,
     then "My name is Dan and I'm a professional arts photographer...".
  2. **Two or more contacts on the show.** `Hello,` with NO name, because they share one email
     and greeting one of them by name tells the others they were an afterthought. Do not write
     "Hi Emma and Tom,": the contact list can change after the draft is written, and Overture
     refuses to send a named greeting on an email reaching more than one person.
  3. **A shared inbox** (`contactMethod: "generic_inbox"`) **where a person's name is known.**
     An `Attn:` line naming that person and their role, a blank line, then `Hello,`, a blank
     line, then the first real sentence:

     ```
     Attn: Raphaele de Boisblanc, Interim Director of Marketing

     Hello,

     My name is Dan and I'm a professional arts photographer here in NYC...
     ```

     The `Attn:` line routes the pitch to the right desk without pretending the email is
     addressed to that person directly, which is why the greeting under it stays impersonal.
     With no name known behind the shared inbox, write `Hello,` alone and no `Attn:` line.

  Nothing else counts as a greeting. "I hope this finds you well" is not one (and is separately
  forbidden as a tell), and neither is diving straight into the first sentence.
- **Subject:** specific, low-key. "Photographing [group]'s [performance] at [venue]."
  This formula stays fixed across drafts; the variety budget below goes into the body.
- **Sentence one always introduces Dan, by name and by trade (Dan, 2026-07-31).** A cold
  reader does not know who is writing, so nothing else may come first: not a credential,
  not an observation, not the reason. Dan's own proven pitch opens "My name is Dan and I'm
  a professional arts photographer here in NYC", and that is the shape every cold draft
  starts from. Reword it every time, never reproduce it verbatim ("My name is Dan, I'm an
  arts photographer here in NYC", "I'm Dan Wright, a performing arts photographer based in
  New York City"). It must carry BOTH his name and what he does. This rule replaced
  an earlier instruction NOT to lead with his name, which was invented to manufacture
  variety and produced openers that started talking before saying who was talking.
  **The exception is `priorRelationship` `booked` or `warm` (#1215):** they already know
  him, the cold self-introduction is wrong for them, and the register bullet above governs
  instead.
- **Always "New York City" or "NYC", never bare "New York" (Dan, 2026-07-31).** Where Dan
  works is the CITY, and the city is a different place from the state. Every reference to
  it in a draft, in his self-introduction and anywhere else, says "New York City" or "NYC"
  ("a performing arts photographer here in NYC", "based in New York City", "venues across
  New York City"). "in New York" alone is a wrong result. This governs Dan's own words
  only: a venue's or an organisation's name is quoted as printed, so Lincoln Center, Radio
  City Music Hall, and a company that calls itself the New York Whatever Ensemble are all
  untouched.
- **Opener archetype, rotate across the run (#362):** the introduction above is fixed, so
  the archetype governs SENTENCE TWO, what the draft does once Dan has said who he is.
  Two shapes. Don't use the same one twice in a row within this run:
  - *Reason-first:* sentence two is the reason for writing, naming the show, its date and
    its venue ("I'm writing in regard to your August 3 show at The Green Room 42"). How he
    shoots comes after.
  - *Direct-intent:* sentence two folds how he works into the reason itself ("I shoot
    unobtrusive, no-flash documentary coverage, and I'm writing about your August 3 show
    at The Green Room 42"), so the draft reaches the offer a beat sooner.

  `credential-first` and `observation-first` are RETIRED (Dan, 2026-07-31). Credential-first
  led with venues before the reader knew what Dan does, which is exactly what sentence one
  now owns. Observation-first only ever had the show's own material to observe, which
  "Name the show, describe nothing" above forbids, and with that gone it reached for
  scarcity ("only one chance at pictures of it") instead. Never write either shape, and
  never echo either token, even if a stale `experimentArmInstruction` names one: write the
  closest live shape and record THAT.

  These shapes describe the FIRST REAL SENTENCE, the one under the greeting, never the greeting
  itself: the greeting is written above them per the opening rule in this section, and none of
  these archetypes replaces it. "I hope this finds you well" is not a greeting and is still
  wrong. Never fabricate a detail to fill a shape.
  If this queue item carries an `experimentArmInstruction` (an A/B experiment assignment,
  one of the live archetype tokens), use THAT archetype for this draft, even when it
  repeats the shape of the draft just before it: the assigned archetype OVERRIDES the
  rotate and don't repeat rule above, so the experiment genuinely randomizes what gets
  produced. The rotation governs only items with NO `experimentArmInstruction`. The one
  thing it does not override is "never fabricate": if the assigned archetype truly cannot
  be written truthfully for this listing, write the closest honest shape instead (you
  record the shape you actually wrote below, so an unavoidable mismatch stays visible).
  Record which archetype you actually used in the `variant` field, as exactly one of
  these two tokens: `reason-first` or `direct-intent`. Record the shape you WROTE (the
  produced opener), never a shape you meant to use but didn't; Overture reads this echo
  only to see which openers land.
- **The middle, 2-4 sentences** (the part between the opener above and the offer below):
  unobtrusive no-flash documentary coverage; why THAT suits
  the night, said in terms of how Dan works rather than what the show is; the portfolio
  link (below). Counted on its own, NOT across the whole email: the fixed self-introduction,
  the offer, the ask and the soft line are each required in their own right, so a finished
  draft runs longer than four sentences and that is correct. **Say the EFFECT, not the vantage point (Dan, 2026-07-31): never "from the
  back of the house" or "back of house".** Where he stands is Dan's problem, not a selling
  point, and a reader who pictures a photographer parked at the back may hear "distant"
  rather than "discreet". Write what the reader actually cares about: that he is
  unobtrusive, that he works without flash, that the audience doesn't notice him and the
  performance isn't disturbed.
  **State every one of those absolutely; never quantify the audience (Dan, 2026-08-14).**
  Not "most audiences", not "usually", "generally", "typically", "often", "rarely",
  "hardly anyone", "barely", "mostly", "for the most part", "tend to", "pretty much" or
  "really", and never "at all" on the end of it. He read "most audiences don't notice I'm
  there at all" in his own outgoing pitch and said: "It implies that some audiences *do*
  notice." A hedge invites the reader to picture the audiences that DID notice, which is
  the exact objection a presenter has about letting a photographer into a performance, and
  "at all" over-corrects on the other end, so one short claim carries a hedge and an
  intensifier at once and reads as somebody arguing with themselves. The same goes for the
  other effect claims here: no flash, the performance not disturbed, documentary rather
  than posed. Say them as facts about how Dan works, not as estimates about a group he
  cannot speak for.
  **And say the audience half ONCE.** "Doesn't distract from what's happening on stage" and
  "the audience doesn't notice me" are one idea in two clauses, so a sentence carrying both
  says the same thing twice. A second clause is fine when it is about the PERFORMANCE rather
  than the audience ("the audience doesn't notice me and the performance isn't disturbed"),
  which is two facts, not one restated.
  Let the length breathe with
  the archetype and the material, a short punchy draft and a slightly fuller one both
  read as normal; don't pad to hit a target length.
- **Offer:** held positively, and carrying NO PRICE AND NO TURNAROUND. Never state the rate,
  never state that the gallery comes back within two weeks, and never link to a contract,
  pricing, or rates page (#612: the site does not have one).

  Dan's call, 2026-07-31, reversing the previous rule that made the rate mandatory: "I feel
  like I'm more likely to get a response if I don't, because they may check out my portfolio
  instead of getting sticker shock and then email me asking about it." A number in a first
  email from a stranger is judged before the work is looked at. Leave the reader with the
  portfolio and the ask, and let them raise money themselves; answering that question in a
  REPLY is a conversation, and a conversation is the point.

  This is about a COLD PITCH. A reply to someone who asks what Dan charges answers in FULL, and
  that answer is fixed text rather than a summary somebody writes fresh each time: see
  "Answering what do you charge" at the end of this section (#2874).
  The original plan called for A/B testing "state the rate" against "link the contract
  page", but that second arm was never real, and the only way to write it is to invent a
  URL that 404s in an email Dan actually sends. There is nothing to choose between here.
  (The `variant` field records the opener archetype above, not this retired offer test.)
- **CTA: an explicit ask that PRESUPPOSES they have photography plans, then a close that
  expects a reply (Dan, 2026-07-31).** Three parts, and each one is doing work:
  - **It must actually REQUEST something.** A message goes out to get an outcome, and a
    door left open is not a request. The 2026-07-31 drafts described the whole offer and
    then asked for nothing, leaving the next step entirely with a stranger.
  - **Ask about their photography plans FOR THIS SHOW, never whether they want photography
    at all.** This is the point of the phrasing, not a stylistic preference. Dan's own pitch
    says "I would love to speak about your photography plans for the performance", which
    takes for granted that plans are a thing this show has: someone who has not thought
    about it now assumes they should have. Rewording it into a yes/no offer ("would you
    like coverage of the show?", "let me know if you're interested", "if photography is
    something you're considering") throws that away and invites a no. Reword the sentence
    every time, keep the presupposition every time. Say "I'd be glad to talk about your
    photography plans" rather than "I'd love to", which the no-enthusiasm rule below rules
    out even though Dan's own reference pitch uses it.
  - **Close by expecting a reply: "I look forward to hearing from you"** or a rewording of
    it. An exclamation mark IS allowed here, and only here (#1906, Dan's call 2026-07-31: it
    is his own sign-off, and he restored it by hand on a real draft). One mark, in the final
    sentence, with none earlier in the email. **"Happy to answer any questions" is RETIRED (Dan,
    2026-07-31)**, along with any variation that asks THEM to produce something ("let me
    know if you have any questions", "feel free to reach out with questions"): inviting
    questions makes the reader do the work of inventing one, when the draft has already
    made the offer and the ask. Never "let me know how that lands" either,
    Dan flagged it as sounding douchey.

  A draft MAY acknowledge they might be covered already ("if you don't have someone on it
  already"), Dan's call 2026-07-31: it is honest about how often a show is already booked.
- **Credential + portfolio link (#365):** work in one of Dan's citable credentials
  (Carnegie Hall tenure of nearly 10 years, or the Madison Square Garden / Lincoln
  Center / Radio City Music Hall venues) plus the portfolio link
  (danwrightphotography.com), so the pitch carries proof, not just an offer. Tailor
  which credential leads to the target venue: a Carnegie-venue show leads with the
  Carnegie tenure, another marquee venue can lead with itself or pair with the
  Carnegie tenure. Vary the phrasing draft to draft; never reproduce Dan's reference
  pitch (dan-wright-brand-voice skill, references/email-and-alt-text.md) verbatim.
- **Say if Dan already knows the room (#1887):** when the item carries `venueHistory`, work that
  fact into the draft ALONGSIDE the credential above, never instead of it (Dan's call,
  2026-07-31). The credential says the level he works at; this says he knows THIS room, and it is
  the one thing in a cold pitch a stranger cannot fake. Use the band's meaning and nothing more
  precise:
  - `shot_before`: he has photographed at this venue before, so he knows the room.
  - `a_few`: he has photographed a few shows there.
  - `regularly`: he shoots there regularly.

  **NEVER state a count.** Not a numeral, not a number word, and not a phrase standing in for one
  ("twice", "a couple of", "three times", "over a dozen"). Dan was explicit: the bands exist so
  the email never claims an exact number. The field carries a band and no number precisely so
  there is nothing to state, and inventing one is a fabricated fact about his own history.

  **The follow-on clause is about FAMILIARITY, never about what could otherwise go wrong**
  (Dan, 2026-07-31). A short phrase after the band is welcome, and it says he knows the space:
  "so I'm familiar with the room", "so I know the space", "so the room isn't new to me". It must
  NEVER be framed as a risk avoided: "so I'm not learning it on the night", "so there's no
  guesswork", "so I won't be finding my angles during the first number". Dan flagged that shape
  himself. Naming the bad outcome plants it in the reader's head and invites them to picture a
  photographer fumbling in an unfamiliar room, which is the opposite of what the sentence is for.

  An ABSENT `venueHistory` means SAY NOTHING about having worked the venue. Never infer it from
  the venue's name, from a past client, or from anything else in the payload. The app omits the
  field when it has no history to report and, deliberately, on a Carnegie Hall show, where the
  Carnegie tenure credential above is already about that exact room and a venue line beside it
  would be the same fact twice.
- **It is MY portfolio, never THE portfolio** (Dan, 2026-07-31). Write "you can see my portfolio
  at danwrightphotography.com", never "you can see the portfolio at ...". The definite article
  makes it sound like a shared company asset rather than his own body of work, and the whole
  email is written in his first person voice.
- **One portfolio link, always the site itself (#1832):** link `danwrightphotography.com` and
  NOTHING deeper. Never a gallery path: not `/music`, `/bands`, `/comedy`, `/dance`, or
  `/performing-arts`. Dan's call, 2026-07-30: "just always go to the same site and let them click
  into the portfolio they want to see." Choosing a gallery is a decision made on the reader's behalf,
  and the reader is better placed to make it. This is ENFORCED at send, not just asked for: the app
  refuses to mail a body carrying a gallery path (`DraftCheck.galleryPathLink`, see below).
  Say what the work IS in the words instead (unobtrusive, no-flash documentary coverage) and let the
  credential carry the rest, without claiming genre experience Dan does not have (see the overclaim
  rule below).
- **Don't overclaim genre experience:** Dan has shot far more concert, choral, and
  opera work than dance. When pitching a dance company or another genre he's less
  experienced in, don't describe genre-specific technique as established practice (for
  example, don't claim a particular way of "moving with the room" for dancers). Keep
  the approach description general (no-flash, unobtrusive documentary style) and let the credentials above carry the confidence instead.
- **Vary the construction WITHIN one email (#2807).** Every rule above is scoped to ONE
  sentence and each supplies its own canonical phrasing, so written back to back they stack
  into an email of a single shape. Dan, 2026-08-16, reading a real draft: "this draft is a lot
  of short sentences and doesn't feel great". Three of its sentences were long, so length was
  not what he was hearing. Three consecutive sentences were built the same way (independent
  clause, comma, "and" or "so", trailing clause) and two of them landed on the same "so ..."
  effect tail: "so the performance isn't disturbed", then "so I'm familiar with the space".

  So **no two sentences in a row may use the same connector construction**. Never two "so ..."
  effect tails back to back, never two ", and ..." trailing clauses back to back, never two
  sentences opening on a fronted "If ..." or "When ..." clause back to back. Dan's own proven
  pitch already does this without being told: compound, simple, compound, fronted-subordinate,
  compound, simple, with no two neighbours alike. Read a finished draft as a sequence of SHAPES
  before writing it out, not as a list of individually correct sentences.

  **Write the body in short paragraphs**, two or three sentences each, rather than one block.
  That is the second fix as well as its own rule: a break between two sentences of the same
  shape resets the cadence for a reader, so either varying the construction or breaking the
  block will do.

  Do NOT reach for a rule about first-person sentence openings. It looks like the same defect
  (six of that draft's eight sentences began with I, I'm, I've or My) and it is not: Dan's own
  reference pitch opens five of its six sentences in first person, three consecutively, a higher
  rate than the draft he objected to. Overture WARNS on the repeated construction
  (`DraftCheck.repeatedSentenceShape`) and says nothing about pronouns. It warns rather than
  refusing the send, because a construction is a judgment about wording, not a fact about the
  text, which is the bar #789 set for a blocker.
- **Anti-repetition within the run (#362):** before finalizing each draft, compare it
  against the one or two drafts immediately before it in this run. Don't reuse the
  same opening line, hook, or distinctive phrase back to back.
- **Anti-repetition across runs (#730):** at the START of the run, read
  `overture-recent-openers.json` (above): its `openers[]` are the opening SENTENCES recent
  runs already used, so separate small batches drafted on different days don't independently
  converge on the same handful of openers. As you draft, don't reopen with a shape or
  distinctive phrase that matches one already in that list; reach for a different archetype or
  a fresh angle instead. Treat it exactly like the within-run check, just with a longer memory
  the app maintains for you. It is shapes to AVOID ONLY: never lift an org, venue, name, or any
  other specific out of it into a draft (the same cross-contamination trap the "Once per run"
  step warns about). If the file is absent or empty (a fresh setup), there is nothing to avoid
  yet, draft normally.

Hard rules: no em dashes; contractions throughout; NO fabrication (only what's real
from the listing, never invent performer states); never volunteer the dance
rate-flexibility in a cold email.

**Never ask for a fact Overture already holds (#438).** Each queue item carries `venue` and
`performanceDate` (every prospect is a specific known show). REFERENCE them, never request them:
"your March 10 concert at Carnegie Hall", never "let me know the date and venue". Asking for known
details reads as careless and undercuts the researched-your-specific-show impression the targeting
is built on. A draft must never request ANY field the work-list already supplies.

**Run dates (#1122).** When an item carries a `runEndDate`, it is a multi-night run, not a single
date: `performanceDate` is the opening night and `runEndDate` is the closing night. Reference the
run, e.g. "your run at BAM, March 10 to 14", not just the opening date. When `openingNightPassed`
is `true`, the opening night has already gone by while later dates remain: pitch only the remaining
dates and NEVER name or reference the passed opening night (writing "your March 10 opening" when
March 10 is behind us reads as a stale, unread listing). Say "the remaining performances" or name a
specific still-upcoming date from the run; when in doubt, refer to the run's closing night, which is
always still ahead in this case.

**No performative enthusiasm (Dan).** Keep it level and professional, not eager.
Avoid "I'd love to", "exactly the kind of work I love", "thrilled", "so excited",
"can't wait", exclamation points, and similar warmth-signaling. State the genuine
reason for reaching out plainly and let the work carry it. "I'd be glad to photograph
it" or "I think my coverage would suit this" over "I'd love to photograph it".

**Venue rule (Dan):** use the recognizable VENUE, not the internal hall. Carnegie's
`Stern Auditorium / Perelman Stage`, `Zankel Hall`, and `Weill Recital Hall` all
become "Carnegie Hall" in the email. Non-Carnegie venues (e.g. Thalia Spanish
Theatre) stay as printed.

**Three of these rules are now enforced at send, not just asked for (#789, #1832).** The app lints the body
it is about to mail (`DraftCheck.blockingFindings`, gating `Recipient.isSendablePending`) and
REFUSES to send a draft that carries any of these, until Dan fixes the text or deliberately
overrides the block:

- **A link to any host other than danwrightphotography.com.** That one host is the only URL a draft
  may contain. There is no pricing page, no contract page, and no client-gallery host
  to point at, so any other link is one the drafter invented, and a 404 in a cold pitch costs the
  lead. Write the rate out in the words instead (see the pricing note above); never link it.
- **A gallery path on that host (#1832)**, like `danwrightphotography.com/music` or
  `/performing-arts`. The link is the site itself; the reader clicks into whichever gallery they
  want. The five gallery paths are the only refused ones, so a page Dan links deliberately (an
  about or contact page) is untouched.
- **An unfilled placeholder**, like `[VENUE]` or `[NAME]`. Fill every slot from the work-list, or
  rewrite the sentence without it. Square brackets never appear in a finished draft.

This lint reads the text that will ACTUALLY be mailed, which for a `provenance: "performer"` contact
is that contact's own `overrideBody` (below), not the shared `draft.body`. Both are held to it.

**Drafting for a performer contact directly (#634, #639-643).** The shared `draft.body`
above is written in the third person because it was designed for a third party being
told about the act (the act's own marketing contact, a presenter), and it still serves
that audience unchanged. A `provenance: "performer"` contact is different: the email
goes directly to the person the draft would otherwise be describing, so writing about
them in the third person ("I saw Virgile Roche and Nora Calder are making their
debut...") reads like a mail-merge mistake to the one person reading it. For every
`provenance: "performer"` contact, ALSO write that contact's own `overrideBody`,
addressing them directly in second person ("you"/"your") instead: "I saw you and Anna
Pierre are making your U.S. debut..." not "I saw Virgile Roche and Nora Calder are
making their debut...". Everything else about it follows the SAME rules as the shared
body above, INCLUDING the greeting rule (#2545): this contact receives their own email, so
its `overrideBody` opens with its own greeting naming them, "Hi Virgile," then a blank line
then the first sentence. It is a one-person email whatever else is on the show, so the
two-or-more "Hello," case never applies to it. Everything else follows the shared body too:
no performative enthusiasm, no em dashes, no price and no turnaround (the Offer rule
above), the same portfolio link, and the same "never ask for a known
fact" rule. The subject line stays shared and unchanged, third-person subjects read
fine regardless of recipient. When two named performers are pursued for the same
show (§1), each gets their OWN `overrideBody` naming their co-performer correctly,
never a copy-pasted version naming the wrong person.

**Answering "what do you charge": Dan's own two paragraphs, VERBATIM (#2874).** This governs a
REPLY to someone who asked, and nothing else. A cold pitch still carries no rate and no turnaround
(the Offer rule above), so these paragraphs never appear in a first email, and the Prep run you are
reading this as never writes one: the reply drafter does (`docs/reply-classify-runbook.md`), and the
text lives here because this file is the repo's copy of the drafting rules. Where they do apply they
are Dan's words, not a summary to be paraphrased, shortened or re-ordered. Reproduce both paragraphs
exactly, and write only the lines AROUND them: the greeting, the sentence acknowledging what they
asked, and the close referencing their specific show.

    I charge $250/hr plus tax (unless you're tax exempt, in which case I'd just need that documentation) with a minimum of one hour. I only charge for time spent at the performance, so there is no charge for time spent editing afterward. The cost includes the time spent photographing your concert as well as editing and delivery of the full gallery within 2 weeks. There are no extra or hidden fees beyond that, although I do offer some add-ons such as black and white edits and faster turnaround times.

    From there, all photos are delivered via an online gallery where you're able to download both high and web-resolution files, and you have full usage rights to the images so you're free to do whatever you would like to with them.

Substitute the performance word for the context ("your concert" becomes "your show" or "your
performance") and nothing else. The add-ons are named, never priced: if they ask what an add-on
costs, that is a question for Dan, not a number to invent.

Never state the number without the paragraphs that follow it. Everything after the price is what
makes the price read as fair, so a reply that stops at "$250 an hour plus tax" sends the sticker
shock without the answer to it. That is measured, not hypothetical: until #2874 this whole answer
was one parenthetical here, and on 2026-08-17 a real reply to a presenter who asked exactly this
came back with the rate, the minimum and the turnaround and nothing else. The drafter did not invent
a thin answer, it reproduced the thin answer it was given, faithfully. The same text is in the
`dan-wright-brand-voice` skill, which is the authoritative copy and which the reply run invokes;
`scripts/check-brand-voice-drift.sh` fails if the two sides stop agreeing on these facts.

### 3. Validate before writing (deterministic guard, Phase C / #39)

Applies to the shared `draft.body` AND every contact's `overrideBody`, if any. Reject or
fix a draft body that:
- contains "discount", "flexible", "free", or "complimentary" (no concession language
  in a cold email);
- states a rate, a price, or a delivery turnaround AT ALL (#1906: a cold pitch carries
  neither. A reply to someone who asked carries all of it, through the canonical two
  paragraphs above, and this validation does not apply to that reply);
- contains performative enthusiasm: "love to", "thrilled", "excited", "can't wait",
  "delighted", or an exclamation point ANYWHERE EXCEPT the final closing sentence
  (#1906, Dan's call 2026-07-31: "I look forward to hearing from you!" is his own sign-off
  and is allowed; one mark, at the very end, and none earlier). Rephrase level before writing.

### 4. Keep the results file current (#1023)

Before moving to the next item in the work-list, rewrite the results file the prompt named
with the complete `PrepResults` JSON covering every item finished so far (see "Input /
output" above). Do this for every item, including one where you found no contact or wrote
no draft, "finished" means you are done working it, not that it succeeded. The launcher
script derives the "N of M" progress display from this file's entry count on its own, so
you never write the progress file yourself.

## One-time setup

If Overture is not installed yet, build and install the resident app first: `cd mac
&& ./build-install.sh --launch` (builds Release, installs to `/Applications`, and
starts it as a login agent).

**Pointing the app at the runner script is no longer a step (#2838).** `build-install.sh` above
already did it: it writes `prepRunnerScriptPath` into the Release preferences domain from its own repo
root and makes the script executable. `mac/scripts/run-debug.sh` does the same for
`com.danwright.overture.debug` when it launches a Debug build, which is what the second command here
used to be for: the two builds read different preferences domains, so one command could never
configure both.

If the checkout MOVES, nothing needs correcting: a stored path naming nothing runnable falls back to
the checkout recorded in `installed-build.json` (`RunnerScripts.resolve`). A stored path that still
works is left alone, so pointing a build at another checkout's script by hand keeps working.

If no script is found either way, the button writes the work-list and reports that it could not find
the Prep runner, naming the setting and what it points at (graceful, no crash). The first real run
should be watched once to confirm the headless `claude -p` launch and the results file land.

## Notes

- A fresh (never-drafted) prospect is the normal queue item. Since #367, a drafted or approved
  prospect can also appear if Dan explicitly asked to re-prep it (see `reprepMode` above); the app
  never adds one of these without Dan asking. A draft Dan hand-edited is never overwritten on
  re-ingest (PrepImporter), and the app also defensively ignores a `draft`/`contacts` update the
  run emits outside what the item's `reprepMode` actually asked for, so getting `reprepMode` wrong
  degrades gracefully rather than silently overwriting something Dan didn't want touched.
- Results that match no kept prospect are surfaced by the app ("N didn't match"), not
  swallowed: a sign the key was rebuilt instead of copied.
