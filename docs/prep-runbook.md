# Prep runbook (Trigger 2)

How the Prep run finds a contact and drafts an email for each kept prospect. The run
is a Claude Code workflow on Dan's Max plan, launched DETACHED by the app's "Prep
kept" button (it never supervises the run). The run reads the work-list, does the
research and drafting, and writes the results file the app ingests for review.

Proven end-to-end on one real prospect (Indianapolis Children's Choir → Emma
Robinson, Marketing & Communications Manager, verified email from the staff page)
before this was codified.

## Input / output (exact)

- **Read:** `~/Library/Application Support/Overture/overture-prep-queue.json`
  (`PrepQueue` version `8`: a run-level `houses[]` (see "The queue names the houses" in §1),
  plus `items[]` each with `naturalKey`, `groupName`, `venue`,
  `performanceDate`, `runEndDate`, `discipline`, `websiteURL`, `sourceListingURL`,
  `possibleMatchName`, `priorRelationship`, `production`, `reprepMode`,
  `openingNightPassed`, `experimentArmInstruction`, `alsoAnswersFor`, `showListing`). `production` is `self` / `agency` / `unknown`; a v1 item omits it
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
- **Write:** `~/Library/Application Support/Overture/overture-prep-results.json`
  (`PrepResults` version `8`: `results[]` each with `naturalKey`, `contacts[]`, `draft`, an
  optional `alreadyCoveredNote` (see the already-covered fit-risk flag in §1 below), an
  optional `emptyReason` REQUIRED on any entry whose `contacts` is absent, see "Say WHY an
  entry has no contacts" in §1, and (v8, #1824) an optional `showSummary` with a
  `showSummaryAbsentReason` REQUIRED whenever there is no summary, see §2's step on grounding a
  draft in the listing. This number had said `5` since v5 while real runs wrote v6;
  corrected with the v7 bump in #1722.)
  Each entry in `contacts[]` is one party to email for the performance, carrying a
  `provenance` of `act`, `performer`, or `presenter` (never the host venue). Emit either
  the act OR its named lead performer(s), never both, see §1 below, plus at most one
  real presenting org; the app sends one separate email per contact. A `provenance:
  "performer"` contact MAY also carry its own `overrideBody`, a direct second-person
  draft for that specific contact (see §2's "Drafting for a performer contact directly"),
  used instead of the shared `draft.body` when the app sends to them. (The legacy v1
  shape carried a single `contact` object; the app still reads it, but new runs MUST
  write `contacts[]`.)
- **Read (optional, #119 voice learning):**
  `~/Library/Application Support/Overture/overture-voice-feedback.json` (`VoiceFeedback`:
  `pairs[]`, each the AI draft vs. what Dan actually sent). Absent or empty on a fresh
  setup. Skip the learning step when so. See "Once per run" below.
- **Read (optional, #730 cross-run anti-repetition):**
  `~/Library/Application Support/Overture/overture-recent-openers.json` (`RecentOpeners`:
  `openers[]`, each the opening SENTENCE a recent draft already used, newest first). Absent
  or empty on a fresh setup. These are shapes to AVOID reusing this run, NEVER a source of
  facts. See §2's anti-repetition rule.
- **Write (optional, #119 voice learning):**
  `~/Library/Application Support/Overture/overture-voice-guidance.md`: the distilled,
  anonymized voice tendencies, an editable artifact. You regenerate ONLY its
  auto-generated section; Dan's own notes section is preserved untouched.
- **Write incrementally as you go (#1023):** rewrite `overture-prep-results.json` with the
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
per research, and Dan is owed an answer for every show he selected. A key you leave out of the results
is reported to him as unchecked, which is correct but wasteful, so emit them all.

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
    her against this performance or find a contact for her: in that case still emit a FULL
    contact for her, `provenance: "performer"`, her `name`, `confidence: "low"`, and a
    `method` (the waterfall method for however she can be reached, e.g. `form_or_dm`),
    leaving `email` and `sourceUrl` absent when you have not verified one. A name-only
    entry still needs its `method`; never omit a required contact field. Dropping a named
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
- **`production != "self"`** (agency-produced or unknown): the waterfall below runs
  exactly as it does today, targeting the act with `provenance: "act"`. Nothing changes.

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

**`websiteURL` may point to the venue, not the act.** If it resolves to the host venue's
site, do NOT harvest a contact from it; find the act's (or the named performer's) OWN
site. Landing on the venue's staff page is exactly the bug this rule prevents.

**The waterfall.** Run this once for the act, or once per named performer when pursuing
performers individually (the target below is whichever of those this run is for). Walk
in order, stop at the first that works:

1. **The target's named decision-maker / direct email.** For the act, whoever owns its
   photography/marketing, read off its own staff/contact page. For a named performer,
   their own published email, read off their own site/bio/contact page.
2. **The target's generic inbox** (info@, the ensemble's published address; a solo
   performer rarely has one of these), never a press/media/PR inbox, see the hard
   press/media-disqualify rule above. A real email for the target, even a generic one,
   is PREFERRED over a contact form.

   **A named contact behind a generic inbox (#610).** While reading the target's own site for
   this step, you may also come across a specific individual (e.g. a PR associate director, an
   administrative director) named on a staff or press page. If so, ALSO set `name` (and `role`
   when the page states one) on this `generic_inbox` contact, so the app can address the pitch
   to a specific desk instead of a shared one. Same STRICT verification bar as elsewhere: only
   an explicit name actually read from a real page counts, never inferred or pattern-guessed.
   This never changes the contact's `method` or `confidence` (still `generic_inbox` / `medium`)
   and never applies to a `form_or_dm` contact.
3. **The target's contact form / Instagram DM** when it publishes no email. Record it
   as `method: "form_or_dm"` with the form URL in `formUrl` (the app surfaces it as a
   tappable link). This outranks any venue inbox.
4. **A genuine presenting org** (the presenter named for the show, NOT the venue). Find its
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
  organisation named for this show that is not on `houses`; until then the lookup is unfinished
  and this token would claim more than you measured.

This is the ONLY trace a refusal leaves, because the rules above tell you never to emit a
venue or press address at any confidence. Without it the app cannot tell a check that found
the room's own inbox and correctly refused it from one that found nothing at all, and Dan's
card says "No email found" in both cases, which claims the search came up empty when it came
up with something. Report what you actually measured. If you genuinely cannot tell which of
the three applies, omit `emptyReason` rather than guessing: the card then falls back to the
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

**Before you draft, read what the show IS (#1824).** Nothing used to tell you. `sourceListingURL`
was handed over and never mentioned again, and on 2026-07-30 one singer-songwriter's cabaret concert
was pitched as if the reader were an organisation, with the only nod to the material ("intimate,
funny") naming nothing. The listing said outright what it was.

You cannot open that page yourself: it is drawn by JavaScript and your tools cannot render it (the
same run fetched the URL, got an 11KB shell, asked for a browser and was refused). So the app renders
it for you and hands over the text in the item's `showListing`. Three states, and they are three
different answers:

- **`status: "read"`.** `text` is that page's readable text. Read it FIRST and let it decide what the
  show is in your draft: a cabaret concert of one songwriter's new songs, a staged opera, a programme
  of new work for string quartet, a stand-up bill. Use only what the page actually says, exactly the
  grounding discipline that applies everywhere else here. If `truncated` is `true`, the page was cut
  at 4000 characters and what you hold may not be all of it.
- **`status: "unreadable"`.** The app could not read that page. You do not know what this show is
  beyond the queue's own fields. Do not go hunting for the page, and do not infer the show from its
  title: "Don't Be So Hard on Yourself" tells you nothing about what happens on stage.
- **absent.** There was no listing page to read at all.

**A listing URL is often not this show's own page.** Roughly a third of them point at a season
calendar or an index (`/opportunities/`, `/show-schedule.html`, `/calendar-events/`). If the text you
were handed does not describe THIS show on THIS date, that is a page that published no description of
it, NOT a licence to describe this show from the neighbouring listings. **"No description published"
is a correct and complete answer**, and a draft that says nothing specific about the material is far
better than one that says something invented.

**Record what you found**, on this item's result entry, so the answer leaves a trace instead of living
only in your head:

- `showSummary`: one plain line saying what this show is, in your own words but sourced entirely from
  the page ("A cabaret concert of new songs by one songwriter, with a cast of five, 75 minutes").
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
  Dan requires a claim about who is reading, so make none: say what HE does ("I photograph performing
  arts in New York", "I'm a documentary photographer here in New York") and let the next sentence name
  THIS show. Never open with a category the reader has to fit ("performing arts organizations",
  "companies like yours", "arts institutions"), and never call a recipient an organisation, a company,
  an institution, a team or an ensemble unless the work-list or the listing actually says so. A solo
  artist, a duo, and a producing company all get the same self-introduction.
- **No greeting in the body (#393).** The drafted `body` MUST start at the first real
  sentence with NO greeting token: write "I photograph performing arts in New York and
  saw..." NOT "Hi Emma, I photograph...". The app owns the greeting and renders it per
  recipient at send (`Salutation.greeting(for:)`), so the same salutation-free body can go
  to the act and to a differently-named presenter. A body that opens with "Hi <name>," is a
  wrong result.
- **Subject:** specific, low-key. "Photographing [group]'s [performance] at [venue]."
  This formula stays fixed across drafts; the variety budget below goes into the body.
- **Opener archetype, rotate across the run (#362):** pick ONE of these four shapes
  for each draft, and don't use the same shape twice in a row within this run:
  - *Reason-first:* open on the genuine, specific reason for reaching out, group and
    performance named correctly ("I photograph performing arts in New York and saw
    [group]'s upcoming [performance]...").
  - *Credential-first:* open by leading with the relevant credential from the
    Credential + portfolio bullet below, then connect it to this performance.
  - *Observation-first:* open on a specific, real detail about the performance,
    venue, or program (something from the listing, never invented).
  - *Direct-intent:* a plain, unadorned statement of what Dan does and why he's
    writing, no throat-clearing.

  No greeting token in any shape ("I hope this finds you well" and "Hi Emma," are
  both wrong), and never fabricate a detail to fill a shape, if the listing doesn't
  supply what an archetype needs for this prospect, use a different one.
  If this queue item carries an `experimentArmInstruction` (an A/B experiment assignment,
  one of the four archetype tokens), use THAT archetype for this draft, even when it
  repeats the shape of the draft just before it: the assigned archetype OVERRIDES the
  rotate and don't repeat rule above, so the experiment genuinely randomizes what gets
  produced. The rotation governs only items with NO `experimentArmInstruction`. The one
  thing it does not override is "never fabricate": if the assigned archetype truly cannot
  be written truthfully for this listing, write the closest honest shape instead (you
  record the shape you actually wrote below, so an unavoidable mismatch stays visible).
  Record which archetype you actually used in the `variant` field, as exactly one of
  these four tokens: `reason-first`, `credential-first`, `observation-first`,
  `direct-intent`. Record the shape you WROTE (the produced opener), never a shape you
  meant to use but didn't; Overture reads this echo only to see which openers land.
- **Body, 2-4 sentences:** unobtrusive no-flash documentary coverage; why it fits this
  performance; a discipline-matched gallery link (below). Let the length breathe with
  the archetype and the material, a short punchy draft and a slightly fuller one both
  read as normal; don't pad to hit a target length.
- **Offer:** held positively, and ALWAYS state the rate plainly ($250 an hour plus tax,
  one-hour minimum, gallery within two weeks).
  **Never link to a contract, pricing, or rates page: the site does not have one** (#612).
  The original plan called for A/B testing "state the rate" against "link the contract
  page", but that second arm was never real, and the only way to write it is to invent a
  URL that 404s in an email Dan actually sends. There is nothing to choose between here.
  (The `variant` field records the opener archetype above, not this retired offer test.)
- **CTA:** soft. "Happy to answer any questions." Never "let me know how that lands,"
  Dan flagged it as sounding douchey.
- **Credential + portfolio link (#365):** work in one of Dan's citable credentials
  (Carnegie Hall tenure of nearly 10 years, or the Madison Square Garden / Lincoln
  Center / Radio City Music Hall venues) plus the portfolio link
  (danwrightphotography.com), so the pitch carries proof, not just an offer. Tailor
  which credential leads to the target venue: a Carnegie-venue show leads with the
  Carnegie tenure, another marquee venue can lead with itself or pair with the
  Carnegie tenure. Vary the phrasing draft to draft; never reproduce Dan's reference
  pitch (dan-wright-brand-voice skill, references/email-and-alt-text.md) verbatim.
- **Discipline-matched portfolio link (#1405):** point the portfolio link at the gallery
  for the show's discipline, so the recipient lands on relevant work rather than the general
  site. Use exactly these gallery URLs and never invent one: music links
  danwrightphotography.com/music, band links danwrightphotography.com/bands, comedy links
  danwrightphotography.com/comedy, dance links danwrightphotography.com/dance, and opera or
  theater links danwrightphotography.com/performing-arts (that gallery is Dan's theater and
  opera work). This strengthens the same pitch honestly, showing relevant work
  rather than claiming genre experience Dan does not have (see the overclaim rule below).
  **When `discipline` does not fit any of them (`other`, or a value the listing plainly contradicts),
  pick the gallery from what the show actually IS (#1824)**, using the `showListing` text above: a
  cabaret, play or musical links performing-arts, a concert or recital links music, a stand-up or
  sketch night links comedy, a band bill links bands, a dance programme links dance. Only from what the
  page says, never from the title or the venue: with no readable listing there is nothing to judge on,
  and the main site danwrightphotography.com stays the honest answer, as it does for any discipline
  none of the five galleries fits. (The Alex Syiek draft fell back to the bare site for exactly this
  reason: nothing had read the page that called it a cabaret concert.)
- **Don't overclaim genre experience:** Dan has shot far more concert, choral, and
  opera work than dance. When pitching a dance company or another genre he's less
  experienced in, don't describe genre-specific technique as established practice (for
  example, don't claim a particular way of "moving with the room" for dancers). Keep
  the approach description general (no-flash, unobtrusive, back-of-house documentary
  style) and let the credentials above carry the confidence instead.
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

**Gallery mapping** (discipline → the closest of the five site galleries):
- music / classical recital → danwrightphotography.com/music
- staged opera / theater → danwrightphotography.com/performing-arts
- dance → danwrightphotography.com/dance
- band → danwrightphotography.com/bands
- comedy → danwrightphotography.com/comedy

**Two of these rules are now enforced at send, not just asked for (#789).** The app lints the body
it is about to mail (`DraftCheck.blockingFindings`, gating `Recipient.isSendablePending`) and
REFUSES to send a draft that carries either of these, until Dan fixes the text or deliberately
overrides the block:

- **A link to any host other than danwrightphotography.com.** The gallery links above are the only
  URLs a draft may contain. There is no pricing page, no contract page, and no client-gallery host
  to point at, so any other link is one the drafter invented, and a 404 in a cold pitch costs the
  lead. Write the rate out in the words instead (see the pricing note above); never link it.
- **An unfilled placeholder**, like `[VENUE]` or `[NAME]`. Fill every slot from the work-list, or
  rewrite the sentence without it. Square brackets never appear in a finished draft.

This lint reads the text that will ACTUALLY be mailed, which for a `provenance: "performer"` contact
is that contact's own `overrideBody` (below), not the shared `draft.body`. Both are held to it.

**Drafting for a performer contact directly (#634, #639-643).** The shared `draft.body`
above is written in the third person because it was designed for a third party being
told about the act (the act's own marketing contact, a presenter), and it still serves
that audience unchanged. A `provenance: "performer"` contact is different: the email
goes directly to the person the draft would otherwise be describing, so writing about
them in the third person ("I saw Virgile Roche and Anna Pierre are making their
debut...") reads like a mail-merge mistake to the one person reading it. For every
`provenance: "performer"` contact, ALSO write that contact's own `overrideBody`,
addressing them directly in second person ("you"/"your") instead: "I saw you and Anna
Pierre are making your U.S. debut..." not "I saw Virgile Roche and Anna Pierre are
making their debut...". Everything else about it follows the SAME rules as the shared
body above: no greeting token (the app still injects the greeting separately at send),
no performative enthusiasm, no em dashes, the same canonical rate and A/B offer
handling, the same discipline-matched gallery link, and the same "never ask for a known
fact" rule. The subject line stays shared and unchanged, third-person subjects read
fine regardless of recipient. When two named performers are pursued for the same
show (§1), each gets their OWN `overrideBody` naming their co-performer correctly,
never a copy-pasted version naming the wrong person.

### 3. Validate before writing (deterministic guard, Phase C / #39)

Applies to the shared `draft.body` AND every contact's `overrideBody`, if any. Reject or
fix a draft body that:
- contains "discount", "flexible", "free", or "complimentary" (no concession language
  in a cold email);
- states a rate that is not the canonical "$250 an hour plus tax, one-hour minimum";
- contains performative enthusiasm: "love to", "thrilled", "excited", "can't wait",
  "delighted", or any exclamation point. Rephrase level before writing.

### 4. Keep the results file current (#1023)

Before moving to the next item in the work-list, rewrite `overture-prep-results.json`
with the complete `PrepResults` JSON covering every item finished so far (see "Input /
output" above). Do this for every item, including one where you found no contact or wrote
no draft, "finished" means you are done working it, not that it succeeded. The launcher
script derives the "N of M" progress display from this file's entry count on its own, so
you never write the progress file yourself.

## One-time setup

If Overture is not installed yet, build and install the resident app first: `cd mac
&& ./build-install.sh --launch` (builds Release, installs to `/Applications`, and
starts it as a login agent).

Point the app at the runner script (so the "Prep kept" button can launch it). The
defaults domain depends on which build reads it: the resident Release app reads
`com.danwright.overture`; a Debug build launched from Xcode reads its own
`com.danwright.overture.debug` domain and never sees the Release one. Set whichever
domain matches the app you are actually running (both, if you switch between them):

```
chmod +x mac/scripts/prep-run.sh
# Resident Release app (installed via build-install.sh):
defaults write com.danwright.overture prepRunnerScriptPath "$(pwd)/mac/scripts/prep-run.sh"
# Debug build (run from Xcode):
defaults write com.danwright.overture.debug prepRunnerScriptPath "$(pwd)/mac/scripts/prep-run.sh"
```

Until this is set, the button writes the work-list and reports "couldn't find the
Prep runner" (graceful, no crash). The first real run should be watched once to
confirm the headless `claude -p` launch and the results file land.

## Notes

- A fresh (never-drafted) prospect is the normal queue item. Since #367, a drafted or approved
  prospect can also appear if Dan explicitly asked to re-prep it (see `reprepMode` above); the app
  never adds one of these without Dan asking. A draft Dan hand-edited is never overwritten on
  re-ingest (PrepImporter), and the app also defensively ignores a `draft`/`contacts` update the
  run emits outside what the item's `reprepMode` actually asked for, so getting `reprepMode` wrong
  degrades gracefully rather than silently overwriting something Dan didn't want touched.
- Results that match no kept prospect are surfaced by the app ("N didn't match"), not
  swallowed: a sign the key was rebuilt instead of copied.
