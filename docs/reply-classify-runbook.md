# Reply-classify runbook (#112)

How the reply-classify run reads inbound replies and tags each with an intent, so Overture can
suggest a conversation state for Dan to confirm. The run is a Claude Code workflow on Dan's Max
plan, launched DETACHED by the app when replies need reading. It reads the work-list, classifies,
and writes the results file the app ingests for review. The app never supervises the run.

## Input / output (exact)

- **Read:** `~/Library/Application Support/Overture/overture-reply-classify-queue.json`
  (`ReplyClassifyQueue` version `2`: `items[]` each with `naturalKey`, `groupName`, `venue`,
  `replyText`, and an optional `recipientId`).
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

- `wants_to_book` — they want to go ahead / lock a date / confirm the shoot. The highest-value read;
  a clear yes.
- `interested` — warm and engaged but not yet committing (asking to see more, "we'd love to at some
  point", positive but non-committal).
- `has_question` — they are waiting on an answer from Dan (rate, availability, logistics, scope).
- `declined` — a no for this occasion (booked someone else, no budget, not a fit, "not this time").

Judge the genuine intent, not surface politeness: a warm-sounding note that ends in a no is
`declined`; a brief "what's your rate?" is `has_question`. When a reply mixes signals, pick the
strongest forward intent (a question alongside clear booking intent is `wants_to_book`). The reply
text may include quoted history from earlier in the thread; classify the NEW message, not the quotes.

Write one `results[]` entry per queue item with the echoed `naturalKey` (and the echoed `recipientId`
when the item had one) and the chosen `intent`. Every state Overture sets from this is a SUGGESTION
Dan confirms or corrects (#60), so a wrong read is recoverable, but aim for the genuine intent.

## One-time setup

Point the app at the runner script (so the app can launch it):

```
chmod +x mac/scripts/reply-classify-run.sh
defaults write com.danwright.overture replyClassifyRunnerScriptPath "$(pwd)/mac/scripts/reply-classify-run.sh"
```

Until this is set, the app writes the work-list and the launch fails gracefully (no crash); the
replies simply stay surfaced as "needs a state" for Dan to tag by hand.

## Notes

- A lead Dan has classified by hand (conversation-state source `manual`) is excluded from the queue,
  so the run never overrides his call.
- A fresh reply after a state was already set re-queues the lead, so an "actually, yes" turnaround is
  re-read rather than lost.
