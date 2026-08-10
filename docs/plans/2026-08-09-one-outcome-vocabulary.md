# One outcome vocabulary for every show

Decided with Dan on 2026-08-09, in a question-by-question interview that started from a
screenshot of one reached-out row carrying both a "Set a state" menu and a "Close this out"
menu. His words: "having these both seem like overkill".

This document records the decisions and the evidence behind them. It is the design; the
milestone of the same name holds one issue per phase.

## The problem, measured

Overture has **seven** separate lists a person or the app can pick a disposition from, holding
about 28 options between them, describing maybe a dozen actual facts:

| # | List | Where | Options |
|---|---|---|---|
| 1 | `DismissReason` | queue card, before pitching | 7 pickable, 2 automatic |
| 2 | `ConversationState` | reached-out row, Follow-ups, full card, reply sheet | 4 |
| 3 | `ReachedOutClose.Outcome` | reached-out row only | 4 |
| 4 | the "Mark…" menu | full card and Archive only | 5 plus Remove |
| 5 | `InquiryLostReason` | inbound inquiries only | 3 |
| 6 | `StandDownCopy` ("Not this one") | Follow-ups only | 2, and it alone asks contact-or-show |
| 7 | `Outcome` (show level) | no picker at all, but reports read it | 5 |

Three defects fall straight out of that, all confirmed against the code and the live store:

**The silent one, and the reason this matters.** Nothing in the app ever writes the show-level
`lostSoft` or `lostHard`. Every writer of `Prospect.outcome` writes only `booked`, `replied`
(debug staging) or `noResponse`. `closeOutFromRow` records the ending on the CONTACT and only
touches the show when the answer is `booked`. Two readers depend on those never-written values:
`OutcomeStats.tally` (so the funnel's lost count is structurally zero and every closed-out show
is filed as "no response") and `LocalHistory` (so Overture can learn an org booked Dan and can
never learn one turned him down; they return next season ranked as if nothing happened). This is
L83: one fact with two homes, written to one and read from the other.

**"Booked" means two opposite things.** "Already booked" on the dismiss list means Dan was busy.
"Booked" on the close-out and Mark lists means the client hired him.

**"Declined" duplicates "Closed (not now)".** Both write `declinedSoft`. Same record, two names,
one line apart on the same row. This is #2388, the issue that started the session.

Live store, read-only, 2026-08-09: 157 recipients, 6 pitched, 5 distinct shows. Every resolution
field empty but one. Nothing has ever been closed out and nothing has ever been marked declined.
**So the migration cost of this change is currently zero, and grows from here.** That is the single
strongest argument for doing it now.

## The decisions

**Q1. The unit of reporting is the SHOW.** Dan does not think in contacts. His words: "I really
don't care about contact level outcomes. All I care about is the event level. Contact only
matters because it might tell me who to reach out to in the future." Note this REVERSES the model
built in #389/#447, where outcomes live on contacts and the show's status is derived from them,
and the show-level picker was deliberately removed. Contacts keep only routing facts: this address
bounced, this person replied, use this one next time.

**Q3. The Reached out row becomes one row per SHOW**, not one per contact. Measured: 4 of the 5
pitched shows have exactly one sent contact, so today this changes almost nothing on screen. It
starts to matter when #51 (one email to several contacts) lands, and one show in the store already
carries 17 contacts. The row must still name WHO replied when someone does, and answering still
goes back to that person.

**Q6/Q7. There is ONE list, not two controls.** Dan: "we shouldn't have both state and close out.
It feels like it's supposed to be the same thing? state is mostly just trying to capture the
outcome." And then, on whether the three live values earn their place: **drop all three.** So
`ConversationState` (Interested, Wants to book, Has a question, Declined) goes away entirely.

**Q4. Five endings for a show that was pitched:**

> Booked · Never heard back · They said not now · They said no · I turned them down

The fifth replaces the stored `stoodDown`, whose current wording is "You stopped working this".
Dan rejected that framing: "I will never stop working something without closure. Either they
didn't respond/turned me down or I turned them down." So it is an active refusal, not an
abandonment.

**Q10. Seven reasons for a show that was never pitched**, in the SAME field:

> Date conflict · I had paid work · Pitching other shows that night · Too soon · Not a fit ·
> Don't want to shoot this · Duplicate

plus `Went by` and `Too far`, which Overture writes for itself and never offers. "I had paid work"
is the rename of "Already booked" that kills the collision.

**One field, two menus.** Twelve pickable values in one column, so the report reads one column in
one pass. Which menu appears depends on whether anything was sent, so an impossible option is
never shown. Whether a show was pitched is already knowable from the send record and is not
encoded in the words.

**Never pitched is NOT lost.** Dan, on the reporting: "I don't think we should count scouted but
not pitched as 'lost'. I do think it's worth counting though." So the report has three groups, not
two: never pitched (with reasons), pitched and booked, pitched and lost (with reasons).

**Q8/Q9. The nudge machinery.** With the states gone, the conversation reminder track loses its
input entirely, along with its three interval settings, the two-day "you haven't said where this
stands" chase, the AI's guess at the state, and the Confirm button beside it. What Dan chose:

- Nothing is closed unless he closed it. "Assume it's not closed lost if I haven't set a state
  that says it's closed."
- Emails stay capped as they are: the pitch plus two follow-ups, then stop.
- After that the show goes quiet until its date. **It must carry a visible marker saying it has
  been emailed three times and will not nudge again**, because a spent row currently looks
  identical to one nobody got to.
- The silent-follow-up track (`FollowUp`) is unaffected and survives as-is.

## The last two decisions, settled the same evening

**Inbound inquiries adopt the SAME five endings.** Their three (They declined, Not a fit for me,
Never heard back) already ARE three of the five under different spellings, and `neverHeardBack` was
deliberately given one shared stored value across both halves of the funnel so they could be added
together. This finishes that job for the other two, and a season report can read both halves in one
pass.

**The post-event closing note survives, and what it records changes.** Its trigger is the show's
DATE, not anything Dan sets, so it outlives the reminder track being retired in phase 4. Dan's rule
for it: "If I'm sending that, it basically HAS to mean never heard back. If I heard back and they
said not now or something I would have already set that state." So it is offered ONLY when the
contact never replied, and sending it records **Never heard back**. Today `closingNudgeBody`'s send
path resolves the lead to `declinedSoft` in every case, which claims somebody turned Dan down when
nobody ever wrote back (`mac/Overture/Integration/SendService.swift:282`).

Claude's inference from that rule, NOT Dan's decision, recorded here so it can be accepted or
dropped when phase 4 is built: a show whose date passes after they DID reply, with no ending
recorded, presumably wants a different prompt (close this out, because Dan already knows what
happened) rather than the closing note.

## Phases

1. One outcome field carrying the twelve-value vocabulary, with the terminal set named once.
2. Two menus over that one field: the dismiss menu and the close-out menu, each offering only
   what is possible.
3. One row per show in Reached out, naming who replied.
4. Retire `ConversationState`, its four surfaces, its reminder cadence, and the AI state guess.
5. Cap the emails at two and show the spent marker on the row.
6. Point `OutcomeStats` and `LocalHistory` at the one field, with never-pitched counted as its own
   group rather than folded into lost.
7. Inquiries adopt the same five endings.

Phase 4 also carries the closing note change: offered only when they never replied, and recording
Never heard back rather than a soft no.

## Related issues

- #2388, the duplicate that started this. Subsumed by phases 1 and 2.
- #2249, "Look at the Reached out row now that it can show four controls at once". Same row, same
  moment, and its proposed fix (make close-out conditional) is overtaken by phase 3.
- #2123, a conversation state set on one contact does not reach the others. Dissolves with phase 4.
- #1741, combine the Reached out and Follow-ups pills. Touches the same surfaces as phase 3.
- #51, one email to several contacts. The reason phase 3 matters.
- #16, the reporting this whole vocabulary exists to produce.
