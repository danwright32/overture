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
  (`PrepQueue` version `2`: `items[]` each with `naturalKey`, `groupName`, `venue`,
  `performanceDate`, `discipline`, `websiteURL`, `sourceListingURL`,
  `possibleMatchName`, `priorRelationship`, `production`). `production` is
  `self` / `agency` / `unknown`; a v1 item omits it (treat as `unknown`).
- **Write:** `~/Library/Application Support/Overture/overture-prep-results.json`
  (`PrepResults` version `4`: `results[]` each with `naturalKey`, `contacts[]`, `draft`).
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
  setup — skip the learning step when so. See "Once per run" below.
- **Write (optional, #119 voice learning):**
  `~/Library/Application Support/Overture/overture-voice-guidance.md` — the distilled,
  anonymized voice tendencies, an editable artifact. You regenerate ONLY its
  auto-generated section; Dan's own notes section is preserved untouched.
- **Update as you go (#354):**
  `~/Library/Application Support/Overture/overture-prep-progress.json` (`PrepProgress`
  version `1`: `{ version, total, completed }`). The launcher script already created this
  file with `completed: 0` and the correct `total` before starting you; after you finish
  EACH item (contact found or not, draft written or not, "finish" means you have moved on
  from it), overwrite the WHOLE file with `completed` incremented by one, `total` and
  `version` unchanged. This drives the app's live "N of M" progress display, so a stale or
  skipped update just makes that count wrong, not a crash, but update it every item, not
  just at the end. Never touch `total`.

**The `naturalKey` is an OPAQUE TOKEN.** Copy it from the queue item into the result
byte-for-byte. NEVER rebuild it from group/date/venue — that is the silent-mismatch
trap. The human-readable fields are for research only.

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
   — a reply is short and responsive, a cold opener introduces him — and don't carry an
   opener's structure into a reply or vice versa. If the file is absent or `pairs` is empty,
   SKIP this whole section and draft from the skill alone — there is nothing to learn yet (the
   normal state on a fresh setup). Pairs are already ordered winners-first, but weight them
   yourself too: an edit on a `booked` or `replied` email is a stronger lesson than one that
   got no response.

2. **Distill ANONYMIZED tendencies.** For each pair, compare the AI draft against what Dan
   sent and capture the PATTERN of the change, never the content: tone (does he level it
   out, cool it down?), length (does he cut, tighten?), word choice (what he swaps in or
   out, e.g. "cover" → "photograph"), structure (what he drops — throat-clearing,
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
   auto-observed tendencies (the weakest signal — gentle nudges only). A tendency NEVER
   overrides the skill or Dan's notes and NEVER reintroduces anything the skill forbids
   (e.g. performative enthusiasm). On any conflict, the skill wins.

## Per prospect

### 1. Find the contact (waterfall, PLAN.md §5)

**Who you are reaching: the performing ACT (or, for a self-produced show, its named
lead performer(s)) — never the host venue (#366 / #368).** The default target is the
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
    them to a third party.
  - If the show is a bigger ensemble/group with no clear individual lead (3+ named
    members, or no performer names available at all), fall through to the standard
    single-act waterfall below with `provenance: "act"`, exactly as for a non-self-produced
    show. This is a judgment call from what the listing actually shows, not a hardcoded
    headcount — when genuinely unsure, prefer the act waterfall.
  - Partial results are fine: emit whichever performers you actually found (0, 1, or 2);
    never block trying to find every one. Dan reviews every draft and can hand-add anyone
    missed via the manual-recipient path.
- **`production != "self"`** (agency-produced or unknown): the waterfall below runs
  exactly as it does today, targeting the act with `provenance: "act"`. Nothing changes.

**Hard venue-disqualify rule (#368), unchanged regardless of target.** Any address
belonging to the host venue is DISQUALIFIED, not a low-confidence fallback. Treat the
`venue` value as the host: its own inbox and its staff addresses are off the table
entirely. Returning a venue address is a wrong result, not a weak one. Better to return
a form/DM, or no contact at all, than the venue. (Interim source for "what counts as
the venue": the queue's `venue` field and its domain; a curated venue map will replace
this, #342.)

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
3. **The target's contact form / Instagram DM** when it publishes no email. Record it
   as `method: "form_or_dm"` with the form URL in `formUrl` (the app surfaces it as a
   tappable link). This outranks any venue inbox.
4. **A genuine presenting org** (the presenter named for the show, NOT the venue). Emit
   the presenter as an ADDITIONAL entry in `contacts[]` with `provenance: "presenter"`,
   alongside the act or performer entries, when you find a real presenting org for the
   show. At most one presenter, and never the host venue. This step is unchanged and
   still runs regardless of `production`; the presenter is always additive, never a
   fallback for a missing act/performer contact.

Each contact you emit becomes its own entry in `contacts[]` with its own `provenance`. If
none of the above yields a non-venue contact for a given target, omit that target from
`contacts[]` rather than reaching for the venue (if that leaves nothing at all, return the
result with the key echoed and `contacts` absent).

**STRICT verification (Dan's rule).** `confidence: "high"` is allowed ONLY for an
address actually READ from a real page; set `formUrl` to that source URL. NEVER emit
a pattern-guessed address (e.g. firstname@org) as high — if you only inferred it, use
`low` and say so. Confidence mapping: named+read = high, generic inbox = medium,
form/DM or inferred = low. **For a named performer specifically**, only use `high` if
the source page corroborates that person against THIS SPECIFIC performance (name plus
instrument/role/context match, e.g. their own site lists this date/venue or names this
group) — a bare name match with no such corroboration is a misidentification risk, so
mark it `low` instead, same as any other unverified guess.

### 2. Draft the email (PLAN.md §7 + the dan-wright-brand-voice skill)

INVOKE the `dan-wright-brand-voice` skill and follow it. Then, as secondary nudges only,
apply the distilled voice guidance from "Once per run" above (the skill always wins). Anatomy:

- **No greeting in the body (#393).** The drafted `body` MUST start at the first real
  sentence with NO greeting token: write "I photograph performing arts in New York and
  saw..." NOT "Hi Emma, I photograph...". The app owns the greeting and renders it per
  recipient at send (`Salutation.greeting(for:)`), so the same salutation-free body can go
  to the act and to a differently-named presenter. A body that opens with "Hi <name>," is a
  wrong result.
- **Subject:** specific, low-key. "Photographing [group]'s [performance] at [venue]."
- **Opener:** a genuine, specific reason, group + performance named correctly. No
  throat-clearing ("I hope this finds you well") and no greeting line.
- **Body, 2-3 sentences:** unobtrusive no-flash documentary coverage; why it fits this
  performance; a discipline-matched gallery link (below).
- **Offer:** held positively. A/B variant — either state the rate plainly ($250 an
  hour plus tax, one-hour minimum, gallery within two weeks) OR link the contract
  page. Record which in `variant`.
- **CTA:** soft. "let me know how that lands."

Hard rules: no em dashes; contractions throughout; NO fabrication (only what's real
from the listing — never invent performer states); never volunteer the dance
rate-flexibility in a cold email.

**Never ask for a fact Overture already holds (#438).** Each queue item carries `venue` and
`performanceDate` (every prospect is a specific known show). REFERENCE them, never request them —
"your March 10 concert at Carnegie Hall", never "let me know the date and venue". Asking for known
details reads as careless and undercuts the researched-your-specific-show impression the targeting
is built on. A draft must never request ANY field the work-list already supplies.

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

### 4. Update progress (#354)

Before moving to the next item in the work-list, overwrite
`overture-prep-progress.json` with `completed` incremented by one (see "Input / output"
above for the exact shape). Do this for every item, including one where you found no
contact or wrote no draft, "finished" means you are done working it, not that it
succeeded.

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

- Already-drafted/approved prospects are excluded from the queue by the app, so the
  run only works fresh ones. A draft Dan hand-edited is never overwritten on re-ingest
  (PrepImporter).
- Results that match no kept prospect are surfaced by the app ("N didn't match"), not
  swallowed — a sign the key was rebuilt instead of copied.
