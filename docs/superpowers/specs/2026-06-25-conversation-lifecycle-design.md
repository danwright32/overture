# Conversation lifecycle design (#111, with #112 as a follow-on)

## Problem

When a lead replies with interest but has not booked yet, the conversation sits in an in-between
state Overture does not model. The existing silent-follow-up sequencer (`FollowUp.swift`, #45/#74)
only nudges leads who went quiet after a send; it auto-stops the moment the outcome is anything but
`no_response`. So a verbal yes, or a question Dan owes a reply to, can quietly go cold with no
reminder to circle back. Warm/replied leads convert far better than cold (~79% vs ~1.6%), so an
active conversation left to drift is the most valuable lead to lose.

This spec covers #111 (the conversation state, the reminders, the due queue, Dan setting it by hand).
#112 (auto-classifying reply intent to set the state) is a clean follow-on, scoped at the end.

## Scope

In scope (#111):
- A `ConversationState` dimension layered on a reply.
- A pure reminder calculator with per-state intervals, surfaced in the existing due queue.
- Automatic clearing when the lead is booked or lost.
- Dan setting and correcting the state from the existing review/outcome surface.

Out of scope (separate issues):
- #112: AI classification of inbound reply intent to suggest the state.
- Any change to the silent-follow-up sequencer's own behavior.

## Model

`Outcome` stays the spine and keeps `booked` and the two `lost` cases terminal. A new dimension
refines a reply:

```
ConversationState: interested | wantsToBook | hasQuestion | declined
```

Stored on `Prospect` as raw strings, matching how `Outcome` / `ReviewStatus` are persisted: the
state itself plus three supporting fields:

- `conversationStateRaw: String?` — the current state (nil = no conversation state yet).
- `conversationStateSetAt: Date?` — when the state was last set; anchors the reminder timing.
- `conversationRemindedAt: Date?` — the last time Dan acted on the reminder; re-anchors it so it
  does not nag every day.
- `conversationStateSource: String?` — `auto` or `manual`, mirroring `OutcomeSource`, so the #112
  AI suggestion never overwrites a state Dan set by hand (the sticky-override pattern from #60).

`ConversationState` is its own enum with a `label` for the UI, mirroring `Outcome`.

## Reminder logic

A `ConversationReminder` calculator parallel to `FollowUp`: pure, never sends, decides who is due.
Per-state intervals live in a `ConversationReminderConfig` struct with these defaults (tunable
later, as `FollowUpConfig` is):

```
wantsToBook -> base interval 7 days after conversationStateSetAt, if still not booked
hasQuestion -> base interval 2 days after (Dan owes a reply)
interested  -> base interval 10 days after
declined    -> never due
leadBufferDays -> 3 (the latest a reminder may fire before the event)
```

### Event-aware timing

The event date (`performanceDate`) is the real deadline: a reminder that fires after the show is
worthless, and a long interval can push it past a near event. So the due date is the EARLIER of the
normal interval and the event minus the lead buffer:

```
anchor   = conversationRemindedAt ?? conversationStateSetAt
dueDate  = anchor + interval(for: state)
if performanceDate is known:
    dueDate = min(dueDate, performanceDate - leadBufferDays)
due = now >= dueDate   (and state active, outcome not booked/lost, event not yet passed)
```

So an `interested` lead (10 day interval) whose event is 5 days out with a 3 day buffer becomes due
in 2 days, not 10; if the event is already within the buffer, the reminder is due immediately. A
prospect with no `performanceDate` falls back to the plain interval.

The date math reuses the app's EXISTING Eastern helpers, it does not add a parallel one: the queue
model already has `easternToday`, `day(_:)` (parse a `YYYY-MM-DD` day string), and
`daysUntil(performanceDate:today:)` (in `QueueView+Model.swift`), and `BookingMatch` has the Eastern
calendar. We extract those into one shared helper and add the single missing primitive (add N days
to a day string, or equivalently reason in `daysUntil` terms). A parallel helper would recreate the
midnight-drift bug #116 exists to kill. "Event has passed" is `daysUntil(performanceDate) < 0` (the
day AFTER the show), matching `daysUntil` returning 0 on the performance day everywhere else, so the
closing nudge never fires on the morning of the show.

No cap while the event is upcoming: the reminder keeps recurring (re-anchored each time Dan acts on
it via `conversationRemindedAt`) until the lead is booked, lost, or the event passes. Dropping an
active verbal yes is the worst case, so it nags until resolved.

`ConversationReminder.due(from:now:config:)` returns the matching prospects with a reason/label per
prospect ("verbal yes, not booked", "owes a reply", "interested, going quiet", and the post-event
"closing note" below) so the due queue can tag them.

### Post-event closing nudge

Once `performanceDate` has passed and the lead is still active and unbooked, the due item becomes a
single gracious closing nudge: a kind, low-key "perhaps another time" note that keeps the
relationship warm for a future season rather than letting it drop silently. Its copy lives in
`ConversationReminder` (a `closingNudgeBody`, in Dan's voice, no performative enthusiasm, no em
dashes), mirroring `FollowUp`'s softer final note, and MUST follow the `dan-wright-brand-voice`
skill when written. Sending it resolves the lead to `lostSoft` (door open, matching "maybe next
time"), which stops all further reminders. Until Dan sends it or marks the lead lost, it stays in
the queue as the one closing action.

### Send path (a dedicated sender)

The closing nudge and any active re-touch CANNOT reuse the existing senders: `SendService.sendOne`
requires an unsent approved lead, and `SendService.sendFollowUp` requires `outcome == noResponse`
and caps at `maxFollowUps` (2). A lead with a conversation state fails both. So we add
`SendService.sendConversationNudge`, which:
- threads onto the original conversation exactly like `sendFollowUp` (`inReplyTo: gmailMessageId`,
  `threadId: gmailThreadId`, a single `Re:` subject) so the reply checker keeps watching the thread,
- does NOT touch `followUpCount` (this is a separate track from the silent sequence, uncapped), and
- on the closing variant, sets `outcome = .lostSoft` with `outcomeSourceRaw = manual`.

Sending an active re-touch stamps `conversationRemindedAt` (the re-anchor); see below.

## Resolution / clearing

- A `booked` outcome (including auto-detection from #99) clears the reminder automatically, because
  the calculator excludes booked/lost leads.
- Any `lost` outcome clears it the same way.
- Setting `declined` maps the outcome to `lostSoft` (door stays open), correctable to `lostHard`.
  This records the decline and stops the reminders in one action. It MUST go through the existing
  `setOutcome` path (which stamps `outcomeSourceRaw = manual`, `outcomeAt`, and clears
  `bookingSuggested`), not a raw write, or the reply checker (`ReplyService`) would silently flip it
  back to `.replied` on the next pass (it only skips manual-sourced or already replied/booked leads).

- A passed event resolves through the closing nudge (above): sending it sets `lostSoft`, which stops
  the reminders. The event passing does not by itself mark the lead lost; it changes the due item to
  the closing note and waits for Dan to send it or mark it lost.

Because clearing is derived from `Outcome` rather than a separate flag, there is no second source of
truth to keep in sync.

## Surfacing

The conversation-state reminders join the same due queue Dan already works the silent follow-ups in,
each tagged by reason so the queue stays one place. Dan sets the conversation state from the existing
outcome/review surface on a prospect that has replied; setting it stamps `conversationStateSetAt` and
`conversationStateSource = manual`.

Setting any conversation state ALSO records the lead as replied when its outcome is still
`noResponse`: it sets `outcome = .replied` with `outcomeSourceRaw = manual` (through the `setOutcome`
path). This covers an offline reply (Dan was told in person, never emailed back) and is what makes
the silent follow-up sequencer stand down, since `FollowUp.due` only fires on `noResponse`. So the
two reminder sources become genuinely mutually exclusive (no lead in both lists) rather than relying
on an assertion. A lead that already replied keeps its existing source.

Every active state gets its OWN pre-written nudge body that Dan reviews and sends, plus the
post-event closing note: `interested`, `wantsToBook`, and `hasQuestion` each have copy in
`ConversationReminder`, all in Dan's voice (no performative enthusiasm, no em dashes, the
`dan-wright-brand-voice` skill). The `hasQuestion` nudge is necessarily generic (a "wanted to make
sure I answered your question, happy to help" style note) since it cannot know the specific question;
Dan can edit before sending, draft-and-approve as always.

Each active reminder also carries an explicit "remind me later" control. Both sending the nudge (via
`sendConversationNudge`) and tapping "remind me later" stamp `conversationRemindedAt` (the
re-anchor), so the reminder steps forward by its interval instead of nagging on every render.

Closing finding-7 gap: a lead whose reply was auto-detected (`ReplyService` set `outcome = .replied`)
but which Dan has not categorized has no conversation state yet, so neither reminder fires. To keep
such a lead from going cold before #112's auto-tagging exists, the due queue surfaces a lightweight
"replied, needs a state" entry for any `replied` lead with no conversation state, prompting Dan to
categorize it. This is a small queue-side prompt, not a new stored field.

## #112 follow-on (not built here)

When a reply is detected (the reply-fetch path behind #74), the AI (Claude on Dan's Max plan, the
same engine that drafts) reads the reply and classifies intent into the same four states, setting
`conversationStateRaw` with `conversationStateSource = auto`. Draft-and-approve in spirit: it
suggests the state, Dan corrects it, and a manual state is never overwritten by a later auto read
(the #60 pattern, already supported by `conversationStateSource`). This spec deliberately builds the
`auto`/`manual` field now so #112 is purely additive.

## Testing

TDD throughout. Pure-logic tests (no SwiftData) for `ConversationReminder`:
- each state's interval boundary (just-before vs at the threshold),
- the re-anchor via `conversationRemindedAt`,
- event-aware timing: a near event pulls the due date earlier than the plain interval; an event
  inside the lead buffer makes it due immediately; a prospect with no `performanceDate` uses the
  plain interval,
- the day-of-show boundary: at 23:59 Eastern on the performance day the ACTIVE reminder still shows
  (event not passed); at 00:00 Eastern the next day it becomes the closing nudge,
- the post-event closing nudge: a passed event on an active, unbooked lead surfaces the closing
  note (not the active reminder), with the right copy, and resolving it to `lostSoft` stops it,
- booked and lost both clear the reminder,
- `declined` is never due,
- the per-prospect reason/label.

Plus tests for:
- the `declined -> lostSoft` mapping going through `setOutcome` (manual source, so `ReplyService`
  does not undo it),
- setting a conversation state on a `noResponse` lead also marks it `replied` (manual), and
  `FollowUp.due` then excludes it (the real no-double-count guard, not an assertion),
- `sendConversationNudge`: it threads onto the original conversation, does not change `followUpCount`,
  and the closing variant sets `outcome = .lostSoft` + manual source,
- the re-anchor: stamping `conversationRemindedAt` steps the next due date forward by the interval,
- the "replied, needs a state" queue entry appears for a `replied` lead with no conversation state
  and disappears once a state is set.

## Risks / notes

- The two reminder sources are made genuinely mutually exclusive by marking a state-set lead
  `replied` (see Surfacing), so a lead never appears in both the silent and conversation lists. The
  integration test pins it rather than trusting the invariant.
- Intervals are first-guess defaults (7 / 2 / 10 days, 3 day lead buffer). They live in config so
  Dan can tune them without a model change.
- Date handling must be Eastern (America/New_York), not UTC, and reuses the app's existing Eastern
  helpers (queue model + booking matcher) rather than a parallel one (see Event-aware timing). "Event
  has passed" is the day AFTER the show (`daysUntil < 0`), so the closing nudge never fires day-of.
- SwiftData migration is safe with no special work: the app uses lightweight migration (plain
  `Schema([Prospect.self])`, no versioned migration plan), and #132 already added defaulted fields
  the same way. The four new fields are defaulted-`nil` optionals (additive), and only `naturalKey`
  is unique, so there is no index or uniqueness concern and no migration test is warranted.
