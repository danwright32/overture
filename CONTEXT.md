# Overture

Overture finds performing arts performances worth pitching for Dan Wright Photography, ranks them by fit, and surfaces them for Dan to review, contact, and pitch. This glossary is the shared language for that domain; it carries no implementation detail.

## Language

### Performances and people

**Performance**:
One show Dan might pitch to photograph. The unit Dan reviews, keeps, drafts, and pitches; exactly one draft and one commercial outcome per performance.
_Avoid_: Prospect (that is the stored code type, not the domain word), lead (informal only), gig, event.

**Act**:
The performers putting on the performance (an ensemble, soloist, company). The party Dan is actually pitching.
_Avoid_: group, artist, performer (use "act" for the billed party).

**Presenter**:
A real presenting organization for the performance, distinct from the host venue. A valid contact only when the act itself is unreachable.
_Avoid_: organizer, producer, host.

**Venue**:
Where the performance happens. NEVER a party Dan pitches; any venue address is disqualified, not a low-confidence option.
_Avoid_: hall, location.

**Recipient**:
One party emailed for a performance: an act contact, a presenter, or one Dan added by hand. A performance has one or more recipients, each emailed separately (own `To`, no shared CC) over the same body.
_Avoid_: contact (overloaded), addressee, target.

**Provenance**:
Where a recipient came from: `act`, `presenter`, or `manual` (Dan typed it in).
_Avoid_: source, origin.

### Sending and engagement

**Send state**:
A recipient's place in sending: `pending` (queued, not yet emailed), `sent` (emailed), or `suppressed` (an unsent send cancelled because the performance froze). Distinct from a performance's review status (new/queued/drafted/approved/contacted/dismissed), which is never called "send state."
_Avoid_: status (reserve "status" for the performance review stage), delivery state.

**First-send rollup**:
A performance's "was this contacted at all" marker: the moment the FIRST recipient was emailed, set once and never changed. Keeps performance-level readers (booking cutoff, reached-out, history, reminders) correct once sending is per-recipient.
_Avoid_: sent date, sentAt (that is the field; this is the concept).

**Silent recipient**:
A recipient who was sent, has not replied, and has not bounced. The only recipients that receive follow-ups or reminders.
_Avoid_: unanswered, pending (that is a send state).

**Bounced**:
A recipient whose email failed to deliver (e.g. a dead guessed-presenter inbox). Excluded from "silent," so it stops getting nudged while live conversations on the same performance continue.

**Freeze the performance**:
The defining rule: any single yes (a reply from any recipient, or a Downbeat booking match) instantly suppresses every not-yet-sent send for that performance and stops every other recipient's follow-up. Only silent recipients are ever nudged, so a landed performance nags no one. Unrelated to `freezeSentCopy`, which merely snapshots the sent email text for voice-learning.
_Avoid_: stand down, settle, lock (for this concept, "freeze the performance" is canonical).
