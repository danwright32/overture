# Reply-classify runbook (#112)

How the reply-classify run reads inbound replies and tags each with an intent, so Overture can
suggest a conversation state for Dan to confirm. The run is a Claude Code workflow on Dan's Max
plan, launched DETACHED by the app when replies need reading. It reads the work-list, classifies,
and writes the results file the app ingests for review. The app never supervises the run.

## Input / output (exact)

- **Read:** `~/Library/Application Support/Overture/overture-reply-classify-queue.json`
  (`ReplyClassifyQueue` version `3`: `items[]` each with `naturalKey`, `groupName`, `venue`,
  `performanceDate`, `replyText`, and `recipientId`. `venue` and `performanceDate` are the show
  details Overture already knows: see the "never ask for known facts" rule below).
- **Write:** `~/Library/Application Support/Overture/overture-reply-classify-results.json`
  (`ReplyClassifyResults` version `2`: `results[]` each with `naturalKey`, `intent`, and the
  `recipientId` echoed back when the queue item carried one).

**The `naturalKey` is an OPAQUE TOKEN.** Copy it from the queue item into the result byte-for-byte.
NEVER rebuild it. **`recipientId` is the same kind of opaque token** (#392): when a queue item
carries one, echo it back verbatim on that result so the intent attaches to the right recipient on a
multi-recipient show; when it is absent, omit it. The human-readable fields are for context only.
Canonical samples of both files (the contract guard, #183) live in `fixtures/reply-classify/`; the v1
files (`queue.json` / `results.json`) and the v2 files (`queue-v2.json` / `results-v2.json`) both
decode under the tolerant gate. Match those shapes exactly.

## Per reply

Read `replyText` and classify the sender's intent as EXACTLY ONE of:

- `wants_to_book`: they want to go ahead / lock a date / confirm the shoot. The highest-value read;
  a clear yes.
- `interested`: warm and engaged but not yet committing (asking to see more, "we'd love to at some
  point", positive but non-committal).
- `has_question`: they are waiting on an answer from Dan (rate, availability, logistics, scope).
- `declined`: a no for this occasion (booked someone else, no budget, not a fit, "not this time").

Judge the genuine intent, not surface politeness: a warm-sounding note that ends in a no is
`declined`; a brief "what's your rate?" is `has_question`. When a reply mixes signals, pick the
strongest forward intent (a question alongside clear booking intent is `wants_to_book`). The reply
text may include quoted history from earlier in the thread; classify the NEW message, not the quotes.

Write one `results[]` entry per queue item with the echoed `naturalKey` (and the echoed `recipientId`
when the item had one) and the chosen `intent`. Every state Overture sets from this is a SUGGESTION
Dan confirms or corrects (#60), so a wrong read is recoverable, but aim for the genuine intent.

## One-time setup

If Overture is not installed yet, build and install the resident app first: `cd mac
&& ./build-install.sh --launch` (builds Release, installs to `/Applications`, and
starts it as a login agent).

**Pointing the app at the runner script is no longer a step (#2838).** The install above already did
it: `build-install.sh` writes `replyClassifyRunnerScriptPath` into the Release preferences domain from
its own repo root and makes the script executable, and `mac/scripts/run-debug.sh` does the same for
`com.danwright.overture.debug`. The two builds read different preferences domains, which is why this
used to be two commands holding an absolute path.

If the checkout MOVES, nothing needs correcting: a stored path naming nothing runnable falls back to
the checkout recorded in `installed-build.json` (`RunnerScripts.resolve`). A stored path that still
works is left alone.

If no script is found either way, the app writes the work-list and the launch fails gracefully (no
crash), naming the setting and what it points at; the replies simply stay surfaced as "needs a state"
for Dan to tag by hand.

## Notes

- A lead Dan has classified by hand (conversation-state source `manual`) is excluded from the queue,
  so the run never overrides his call.
- A fresh reply after a state was already set re-queues the lead, so an "actually, yes" turnaround is
  re-read rather than lost.

## v3 (#420): per-recipient classify + reply drafting

The run now does two jobs per work-list item, per recipient:

1. **Classify** the reply's intent (interested / wants_to_book / has_question / declined). This is a
   NON-BINDING hint on the app side; Dan still marks the binding outcome by hand.
2. **Draft a reply** in Dan's voice that responds to what the contact actually wrote. Emit
   `draftSubject` and `draftBody`.

Rules:

- Each work-list item carries a `recipientId`. Echo BOTH `naturalKey` and `recipientId` verbatim on the
  result so each draft attaches to the right contact. The queue emits one item per replied recipient,
  so two contacts on one show are drafted independently.
- **Dan's voice is defined in exactly one place: the `dan-wright-brand-voice` skill. Invoke it, and draft
  from it (#872).** This is the same skill the Prep run uses, and for the same reason: a reply goes to a
  real person who wrote back to him, so it is his voice or it is nobody's. Until #872 this run had no
  skill and no voice rules at all, and this line told it to "draft from the voice rules in this runbook
  alone" when the runbook held none. It was inventing his voice from the phrase "in Dan's voice".

  Hard rules, from the skill, and absolute:
  - **No em dashes.** Ever. Use commas, colons, periods, or restructure the sentence.
  - **Contractions throughout.** He writes the way he talks.
  - **NO fabrication.** Never invent a fact about the show, the contact, the coverage, or Dan's
    availability. Everything in a draft must be something Overture actually knows or that he actually
    offers.

- Read Dan's distilled voice guidance at `~/Library/Application Support/Overture/overture-voice-guidance.md`
  and apply those tendencies ONLY as secondary nudges: the skill is authoritative and wins wherever the
  two differ, exactly as in Prep. NEVER quote or paraphrase raw past email pairs (the #119/#249 leak
  guard): the guidance file is already the safe, distilled form. If the file is absent, draft from the
  skill alone. It is the authority; the guidance file only ever nudges.
- Keep drafts short, warm, and concrete; include Dan's standing facts only when relevant (rate, two-week
  delivery, unobtrusive no-flash coverage). A `declined` reply still gets a brief, gracious draft.
- **NEVER ask the contact for the date, venue, or location (#438).** Every prospect is a specific known
  show: the queue item carries `venue` and `performanceDate`. REFERENCE them, never request them: write
  "your March 10 concert at Carnegie Hall", never "let me know the date and I'll confirm availability".
  Asking for a fact Overture already holds reads as careless and undercuts the researched-your-show
  impression the whole approach is built on. Ask only about genuinely-unknown things (e.g. confirming
  Dan's own availability, logistics he can't infer). A draft must never request ANY field the queue
  already supplies. If `performanceDate` is absent (a genuinely undated show), simply don't name a date.
- **Write incrementally as you go (#1081):** rewrite `overture-reply-classify-results.json` with the
  complete **version 3** `ReplyClassifyResults` JSON (each result =
  `{naturalKey, recipientId, intent, draftSubject, draftBody}`) covering EVERY item you have finished so
  far, immediately after EACH item, not just at the very end, and nothing else. The launcher script
  derives the reply drafter's live "N of M" progress display by counting the entries in this file itself
  (`ReplyClassifyProgress` version `1`: `{ version, total, completed }`, seeded by the script with
  `completed: 0` and the correct `total`), so the progress count moves forward on its own as this file
  grows. You do NOT write the progress file: asking a model to self-report a count is the exact design
  that left scout's counter stuck at 0 through a live run on 2026-07-16 (#1015), so the script owns it
  now. The only thing you must do for progress is keep this results file current after every single item.

`fixtures/reply-classify/queue-v3.json` and `results-v3.json` are the authoritative spec for this shape.

## After classify: what the app does with the results (shipped)

The drafted reply is not sent automatically. The app attaches `draftSubject` /
`draftBody` to the replied recipient as a suggestion; Dan reads the actual reply in
Gmail, reviews the AI draft in the app, edits it if needed, and sends it himself. The
classified `intent` is the same kind of suggestion: it informs the state the app
proposes, and Dan confirms or corrects it by hand. Neither the intent nor the draft
changes anything on its own.

Every show's overall status (New / Active / Booked / Closed) is derived, not
hand-set: `PerformanceStatus.derive` (`mac/Overture/Domain/PerformanceStatus.swift`)
rolls up all of a show's recipients' send and reply outcomes, with Booked taking
precedence over Active, Active over Closed, and Closed over New. A reply classified
here changes a recipient's resolution, which can move the derived status on its next
read; this run never sets the status directly.
