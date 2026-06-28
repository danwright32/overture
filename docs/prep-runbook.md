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
  (`PrepQueue`: `items[]` each with `naturalKey`, `groupName`, `venue`,
  `performanceDate`, `discipline`, `websiteURL`, `sourceListingURL`,
  `possibleMatchName`, `priorRelationship`).
- **Write:** `~/Library/Application Support/Overture/overture-prep-results.json`
  (`PrepResults`: `results[]` each with `naturalKey`, `contact`, `draft`).
- **Read (optional, #119 voice learning):**
  `~/Library/Application Support/Overture/overture-voice-feedback.json` (`VoiceFeedback`:
  `pairs[]`, each the AI draft vs. what Dan actually sent). Absent or empty on a fresh
  setup — skip the learning step when so. See "Once per run" below.
- **Write (optional, #119 voice learning):**
  `~/Library/Application Support/Overture/overture-voice-guidance.md` — the distilled,
  anonymized voice tendencies, an editable artifact. You regenerate ONLY its
  auto-generated section; Dan's own notes section is preserved untouched.

**The `naturalKey` is an OPAQUE TOKEN.** Copy it from the queue item into the result
byte-for-byte. NEVER rebuild it from group/date/venue — that is the silent-mismatch
trap. The human-readable fields are for research only.

Canonical samples of both files (the cross-language contract guard, #157) live in
`fixtures/prep-queue/` and `fixtures/prep-results/`. Match those shapes exactly; if the
format ever changes, update the fixture and the Swift contract test in the same change.

## Once per run: learn from Dan's recent edits (#119 / #242)

Before drafting anything, fold in how Dan has been revising drafts, so the copy trends
toward send-ready over time. Do this ONCE per run; apply the result to every draft below.

1. **Read the feedback.** Open `overture-voice-feedback.json`. Each `pairs[]` entry holds
   `originalSubject`/`originalBody` (the AI draft) and `sentSubject`/`sentBody` (what Dan
   actually sent), plus `discipline`, `sentAt`, and `outcome` (#245: "booked" / "replied" /
   "no_response" / etc.). If the file is absent or `pairs` is empty, SKIP this whole section
   and draft from the skill alone — there is nothing to learn yet (the normal state on a
   fresh setup). Pairs are already ordered winners-first, but weight them yourself too: an
   edit on a `booked` or `replied` email is a stronger lesson than one that got no response.

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

**Who you are reaching: the performing ACT, never the host venue (#366 / #368).** The
target is the act named in `groupName` (the performers / ensemble / company putting on
the show). The `venue` field is only WHERE the show happens, never who Dan is pitching.

**Hard venue-disqualify rule (#368).** Any address belonging to the host venue is
DISQUALIFIED, not a low-confidence fallback. Treat the `venue` value as the host: its
own inbox and its staff addresses (e.g. `publicrelations@carnegiehall.org` for a show
at Carnegie Hall) are off the table entirely. Returning a venue address is a wrong
result, not a weak one. Better to return a form/DM, or no contact at all, than the
venue. (Interim source for "what counts as the venue": the queue's `venue` field and
its domain; a curated venue map will replace this, #342.)

**`websiteURL` may point to the venue, not the act.** If it resolves to the host venue's
site, do NOT harvest a contact from it; find the act's OWN site (search the
`groupName`). Landing on the venue's staff page is exactly the bug this rule prevents.

Walk in order, stop at the first that works:

1. **The act's named decision-maker / direct email.** Whoever owns the act's
   photography/marketing, read off the ACT's own staff/contact page.
2. **The act's generic inbox** (info@, the ensemble's published address). A real email
   for the act, even a generic one, is PREFERRED over a contact form.
3. **The act's contact form / Instagram DM** when the act publishes no email. Record it
   as `method: "form_or_dm"` with the form URL in `formUrl` (the app surfaces it as a
   tappable link). This outranks any venue inbox.
4. **A genuine presenting org** (the presenter named for the show, NOT the venue) only
   if the act itself is unreachable. Emailing every relevant party (multiple performers
   plus a presenter) is a later capability; for now return the single best ACT contact.

If none of the above yields a non-venue contact, return the result with the key echoed
and `contact` absent rather than reaching for the venue.

**STRICT verification (Dan's rule).** `confidence: "high"` is allowed ONLY for an
address actually READ from a real page; set `formUrl` to that source URL. NEVER emit
a pattern-guessed address (e.g. firstname@org) as high — if you only inferred it, use
`low` and say so. Confidence mapping: named+read = high, generic inbox = medium,
form/DM or inferred = low.

### 2. Draft the email (PLAN.md §7 + the dan-wright-brand-voice skill)

INVOKE the `dan-wright-brand-voice` skill and follow it. Then, as secondary nudges only,
apply the distilled voice guidance from "Once per run" above (the skill always wins). Anatomy:

- **Subject:** specific, low-key. "Photographing [group]'s [performance] at [venue]."
- **Opener:** a genuine, specific reason, group + performance named correctly. No
  throat-clearing ("I hope this finds you well").
- **Body, 2-3 sentences:** unobtrusive no-flash documentary coverage; why it fits this
  performance; a discipline-matched gallery link (below).
- **Offer:** held positively. A/B variant — either state the rate plainly ($250 an
  hour plus tax, one-hour minimum, gallery within two weeks) OR link the contract
  page. Record which in `variant`.
- **CTA:** soft. "let me know how that lands."

Hard rules: no em dashes; contractions throughout; NO fabrication (only what's real
from the listing — never invent performer states); never volunteer the dance
rate-flexibility in a cold email.

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
- choral / music / classical recital → danwrightphotography.com/music
- staged opera / theater → danwrightphotography.com/performing-arts
- dance → danwrightphotography.com/dance
- band → danwrightphotography.com/bands
- comedy → danwrightphotography.com/comedy

### 3. Validate before writing (deterministic guard, Phase C / #39)

Reject or fix a draft body that:
- contains "discount", "flexible", "free", or "complimentary" (no concession language
  in a cold email);
- states a rate that is not the canonical "$250 an hour plus tax, one-hour minimum";
- contains performative enthusiasm: "love to", "thrilled", "excited", "can't wait",
  "delighted", or any exclamation point. Rephrase level before writing.

## One-time setup

Point the app at the runner script (so the "Prep kept" button can launch it):

```
chmod +x mac/scripts/prep-run.sh
defaults write com.danwright.overture prepRunnerScriptPath "$(pwd)/mac/scripts/prep-run.sh"
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
