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

## Resolution / clearing

- A `booked` outcome (including auto-detection from #99) clears the reminder automatically, because
  the calculator excludes booked/lost leads.
- Any `lost` outcome clears it the same way.
- Setting `declined` maps the outcome to `lostSoft` (door stays open), correctable to `lostHard`.
  This records the decline and stops the reminders in one action.

- A passed event resolves through the closing nudge (above): sending it sets `lostSoft`, which stops
  the reminders. The event passing does not by itself mark the lead lost; it changes the due item to
  the closing note and waits for Dan to send it or mark it lost.

Because clearing is derived from `Outcome` rather than a separate flag, there is no second source of
truth to keep in sync.

## Surfacing

The conversation-state reminders join the same due queue Dan already works the silent follow-ups in,
each tagged by reason so the queue stays one place. Dan sets the conversation state from the existing
outcome/review surface on a prospect that has replied; setting it stamps `conversationStateSetAt` and
`conversationStateSource = manual`. Acting on a due reminder (a re-touch) stamps
`conversationRemindedAt`.

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
- the post-event closing nudge: a passed event on an active, unbooked lead surfaces the closing
  note (not the active reminder), with the right copy, and resolving it to `lostSoft` stops it,
- booked and lost both clear the reminder,
- `declined` is never due,
- the per-prospect reason/label.

Plus tests for the `declined -> lostSoft` mapping and for the due-queue integration (conversation
reminders and silent follow-ups coexist in one queue without double-counting a lead).

## Risks / notes

- The due queue now has two reminder sources (silent follow-up and conversation reminder). A lead
  that is both silent and has a stale conversation state should not appear twice; the integration
  test pins this. In practice they are mutually exclusive: the silent sequencer only fires on
  `no_response`, and a conversation state implies a reply, but the test guards it explicitly.
- Intervals are first-guess defaults (7 / 2 / 10 days, 3 day lead buffer). They live in config so
  Dan can tune them without a model change.
- Date handling must be Eastern (America/New_York), not UTC: `performanceDate` is a `YYYY-MM-DD` day
  string, and "event minus the lead buffer" and "event has passed" are day comparisons in Dan's
  timezone, consistent with the rest of Overture (see #116 and the Eastern-dates rule). Getting this
  wrong would fire reminders a day early or late near midnight.
