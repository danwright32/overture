import Foundation

// #2167: what the reached-out row is allowed to show at once, decided in one place.
//
// Every control on that row arrived by its own issue, each defensible alone, and no issue owned the
// combination. This is that missing owner. It is not a redesign: #2154 and #2166 already removed the
// crowding the issue was filed about, and the row's real maximum is three. What was still missing is a
// STATED rule, so a fourth control cannot arrive without somebody deciding it belongs.
//
// #2397: THREE slots now. The conversation-state control went with the states it set, and the row's
// maximum came down with it. Each remaining slot answers a different question, which is why three is not
// stacking:
//
//   timing / answer / passedHint / spentMarker
//                                  when is this due, or who is waiting, or that the night has gone, or
//                                  that the emails are spent and nothing more will go until the show
//   closeOut                       ending the pitch
//   dueAction                      the one thing that is actually due
//
// #2112/#2224 is the fourth control this rule anticipated, decided rather than drifted into. Dan asked
// for it twice in two days and stated the reason plainly: "I'm almost NEVER going to the archive." The
// only control that ended a pitch lived on the Archive card, so in practice the outcome was not recorded
// at all, which empties the reporting the whole funnel exists to produce.
//
// It costs the row nothing in the crowded direction, because the same change collapses the first slot's
// third spelling into it: a show that has been and gone shows the hint INSTEAD of the timing label, not
// beside it. A countdown to a follow-up on a night that has already happened is a promise the row cannot
// keep, so replacing it is better on its own terms and not a concession to the ceiling.
enum ReachedOutRowSlots {
    /// Everything the trailing column may draw, declared in the order it draws them.
    ///
    /// The order is part of the rule rather than an accident of where the `if`s sit: timing leads,
    /// because it is the row's own answer to "why am I looking at this", and the action Dan can take
    /// comes last, where the eye lands after reading.
    /// The first three are one slot with three spellings and exactly one of them ever draws, so their
    /// order relative to each other is not something a person can see. They are listed in the order the
    /// view tries them, which is what makes this comparable to the source.
    enum Slot: CaseIterable, Equatable {
        // #2112: the show has been and gone.
        case passedHint
        // #2398: the emails are done and the show is still open. A fourth spelling of the same question,
        // because "when is this due" has no honest answer once there is nothing left to send.
        case spentMarker
        case timing
        case answer
        // #2112/#2224: ending the pitch, from here rather than from the Archive card.
        case closeOut
        // #2711: recording that a reply arrived on a channel Overture cannot watch, which until now was
        // the one thing about a DM pitch Dan could not tell it. Beside the close-out, because the two are
        // the same kind of act (he is telling Overture what happened somewhere it cannot see) and because
        // a conversation STARTING has to be recordable in the same place a conversation ENDING is.
        //
        // Draws nothing at all on an emailed contact, which is most rows: Overture watches those itself.
        case handMarkedReply
        case dueAction
    }

    /// The slots this row shows, in order.
    ///
    /// `timing`, `answer` and `passedHint` are ONE question with three spellings, so exactly one of them
    /// is always present. That is what stops the row ever rendering as an empty gap, and it is #2166's
    /// rule restated where the ceiling below can see it.
    ///
    /// The precedence is by how much it demands of Dan. Somebody actively waiting on him outranks a date;
    /// a night that has gone outranks a countdown to a follow-up that can no longer help.
    ///
    /// `closeOut` is unconditional, deliberately. A show can get its yes at any moment, and a control
    /// that appeared only once the date had passed would be missing on exactly the night it is wanted.
    /// #2398: `spentMarker` sits between the hint and the countdown. A show whose date has gone is spoken
    /// for by `passedHint` first (that is the stronger fact), and a countdown is only honest while there is
    /// still something to count down to.
    /// #2711: `handMarkedReply` draws only where Overture cannot watch the channel, or where Dan has
    /// already told it a reply arrived there. On every emailed row it is absent, which is why it takes a
    /// parameter rather than being unconditional like `closeOut`: the close-out is always a possible act,
    /// and telling Overture about a reply it can read for itself is not.
    static func slots(replyOffered: Bool, showPassed: Bool = false, nudgesSpent: Bool = false,
                      handMarkedReplyShown: Bool = false, dueActionLabel: String?) -> [Slot] {
        let timingSlot: Slot = showPassed ? .passedHint : (nudgesSpent ? .spentMarker : .timing)
        var slots: [Slot] = [replyOffered ? .answer : timingSlot]
        slots.append(.closeOut)
        if handMarkedReplyShown { slots.append(.handMarkedReply) }
        if dueActionLabel != nil { slots.append(.dueAction) }
        return slots
    }
}
