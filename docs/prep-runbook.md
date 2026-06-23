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

**The `naturalKey` is an OPAQUE TOKEN.** Copy it from the queue item into the result
byte-for-byte. NEVER rebuild it from group/date/venue — that is the silent-mismatch
trap. The human-readable fields are for research only.

## Per prospect

### 1. Find the contact (waterfall, PLAN.md §5)

Walk in order, stop at the first that works:

1. **Named decision-maker.** Prefer whoever owns photography/marketing for the org: a
   Marketing & Communications Manager, Marketing Coordinator, or Development officer,
   then the Artistic/Executive Director. Read their email off a real page (the org's
   staff/contact page, found from `websiteURL` or a web search).
2. **Verified generic inbox** (info@, frontdesk@) read off the org's site.
3. **Web form / Instagram DM** when no email is published.

**STRICT verification (Dan's rule).** `confidence: "high"` is allowed ONLY for an
address actually READ from a real page; set `formUrl` to that source URL. NEVER emit
a pattern-guessed address (e.g. firstname@org) as high — if you only inferred it, use
`low` and say so. Confidence mapping: named+read = high, generic inbox = medium,
form/DM or inferred = low.

### 2. Draft the email (PLAN.md §7 + the dan-wright-brand-voice skill)

INVOKE the `dan-wright-brand-voice` skill and follow it. Anatomy:

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
