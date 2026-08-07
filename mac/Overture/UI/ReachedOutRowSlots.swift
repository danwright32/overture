import Foundation

// #2167: what the reached-out row is allowed to show at once, decided in one place.
//
// Every control on that row arrived by its own issue, each defensible alone, and no issue owned the
// combination. This is that missing owner. It is not a redesign: #2154 and #2166 already removed the
// crowding the issue was filed about, and the row's real maximum is three. What was still missing is a
// STATED rule, so a fourth control cannot arrive without somebody deciding it belongs.
//
// Three slots, each answering a different question, which is why three is not stacking:
//
//   timing / answer   when is this due, or who is waiting
//   conversationState what Dan has said this conversation is
//   dueAction         the one thing that is actually due
enum ReachedOutRowSlots {
    /// Everything the trailing column may draw, declared in the order it draws them.
    ///
    /// The order is part of the rule rather than an accident of where the `if`s sit: timing leads,
    /// because it is the row's own answer to "why am I looking at this", and the action Dan can take
    /// comes last, where the eye lands after reading.
    enum Slot: CaseIterable, Equatable {
        case timing
        case answer
        case conversationState
        case dueAction
    }

    /// The slots this row shows, in order.
    ///
    /// `timing` and `answer` are ONE question with two spellings, so exactly one of them is always
    /// present. That is what stops the row ever rendering as an empty gap, and it is #2166's rule
    /// restated where the ceiling below can see it.
    static func slots(replyOffered: Bool, showsStateControl: Bool, dueActionLabel: String?) -> [Slot] {
        var slots: [Slot] = [replyOffered ? .answer : .timing]
        if showsStateControl { slots.append(.conversationState) }
        if dueActionLabel != nil { slots.append(.dueAction) }
        return slots
    }
}
