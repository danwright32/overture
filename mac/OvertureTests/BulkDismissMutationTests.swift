import Testing
import Foundation
import SwiftData

// #1500: the action itself, driven against a real store. One reason, written to every show on the night,
// as ONE undoable action and ONE acknowledgment.
//
// The reason is the load-bearing part. It writes the same `dismissReason` a per-card dismiss writes, so
// the learning signal, the #1403 funnel counts and the Archive filters are unchanged, and `tooSoon` (a
// missed opportunity, #1128) is never quietly folded into `notInterested`. Bulk dismissal is exactly where
// a wrong reason would get applied to many rows at once.
@MainActor
@Suite("Dismissing a night writes one reason and one undo (#1500)")
struct BulkDismissMutationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Org \(key)", discipline: "music",
                         venue: "Stern Auditorium", performanceDate: "2026-07-24", sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func everyShowOnTheNightIsDismissedForTheOneChosenReason() throws {
        let ctx = try context()
        let a = show(ctx, "a"), b = show(ctx, "b"), c = show(ctx, "c")
        let feedback = ActionFeedback()

        ProspectMutations.dismissAll(["a", "b", "c"], reason: .tooSoon, dateLabel: "Jul 24",
                                     prospects: [a, b, c], context: ctx, feedback: feedback)

        #expect([a, b, c].allSatisfy { $0.status == .dismissed })
        // #1128: "Too soon" is a missed opportunity, never a bad-fit signal, so the raw value written must
        // be its own, not notInterested's.
        #expect([a, b, c].allSatisfy { $0.showOutcomeRaw == "too_soon" })
        #expect([a, b, c].allSatisfy { $0.dismissedAt != nil })   // #16: the exit date every dismiss stamps
    }

    // The whole point of the issue's undo requirement: Cmd+Z gives the night back, not one card per press.
    @Test func theNightIsOneEntryOnTheUndoStack() throws {
        let ctx = try context()
        let a = show(ctx, "a"), b = show(ctx, "b"), c = show(ctx, "c")
        let stack = QueueUndoStack()

        ProspectMutations.dismissAll(["a", "b", "c"], reason: .dateConflict, dateLabel: "Jul 24",
                                     prospects: [a, b, c], context: ctx, feedback: ActionFeedback(),
                                     undo: stack)

        #expect(stack.entries.count == 1)
        #expect(stack.entries.first?.rows.count == 3)
        #expect(stack.undoMenuTitle == "Undo Dismiss: 3 shows on Jul 24")
    }

    // And that one entry actually puts the night back where it came from.
    @Test func onePressAfterwardsRestoresTheWholeNight() throws {
        let ctx = try context()
        let a = show(ctx, "a"), b = show(ctx, "b")
        let stack = QueueUndoStack()
        ProspectMutations.dismissAll(["a", "b"], reason: .dateConflict, dateLabel: "Jul 24",
                                     prospects: [a, b], context: ctx, feedback: ActionFeedback(), undo: stack)

        let entry = try #require(stack.takeTop())
        let outcome = QueueUndo.apply(entry, resolving: { key in [a, b].first { $0.naturalKey == key } },
                                      in: ctx)

        #expect(outcome.restored == 2)
        #expect(a.status == .new)
        #expect(b.status == .new)
        #expect(a.dismissedAt == nil)
    }

    @Test func itSaysHowManyLeftAndWhy() throws {
        let ctx = try context()
        let a = show(ctx, "a"), b = show(ctx, "b")
        let feedback = ActionFeedback()

        ProspectMutations.dismissAll(["a", "b"], reason: .tooSoon, dateLabel: "Jul 24",
                                     prospects: [a, b], context: ctx, feedback: feedback)

        let message = try #require(feedback.message)
        #expect(message.contains("2 shows"))
        #expect(message.contains("Jul 24"))
        #expect(message.contains("Too soon"))
    }

    // A key with no row behind it is an ordinary outcome (rows are deleted at runtime by
    // NaturalKeyVenueMigration), not a reason to abandon the other four.
    @Test func akeyWithNoRowLeftDoesNotStopTheRest() throws {
        let ctx = try context()
        let a = show(ctx, "a")
        let stack = QueueUndoStack()

        ProspectMutations.dismissAll(["a", "gone"], reason: .notAFit, dateLabel: "Jul 24",
                                     prospects: [a], context: ctx, feedback: ActionFeedback(), undo: stack)

        #expect(a.status == .dismissed)
        #expect(stack.entries.first?.rows.count == 1)   // the entry describes what actually happened
    }

    // "Assume it runs twice" (CLAUDE.md). A repeat of the same action changes nothing, so it must not push
    // a second entry: that entry would describe a dismissal that never happened, and the next Cmd+Z would
    // spend itself doing nothing while looking exactly like a working undo.
    @Test func runningItTwiceDoesNotRecordASecondEntry() throws {
        let ctx = try context()
        let a = show(ctx, "a")
        let stack = QueueUndoStack()

        ProspectMutations.dismissAll(["a"], reason: .tooSoon, dateLabel: "Jul 24",
                                     prospects: [a], context: ctx, feedback: ActionFeedback(), undo: stack)
        ProspectMutations.dismissAll(["a"], reason: .tooSoon, dateLabel: "Jul 24",
                                     prospects: [a], context: ctx, feedback: ActionFeedback(), undo: stack)

        #expect(stack.entries.count == 1)
    }

    // A show already dismissed for a DIFFERENT reason is a real re-labelling, so it does count, and the
    // entry has to carry its old reason or undo would clear it instead of putting it back.
    @Test func areLabelledShowKeepsItsOldReasonInTheEntry() throws {
        let ctx = try context()
        let a = show(ctx, "a")
        a.markDismissed(reason: .notAFit)
        try ctx.save()
        let stack = QueueUndoStack()

        ProspectMutations.dismissAll(["a"], reason: .tooSoon, dateLabel: "Jul 24",
                                     prospects: [a], context: ctx, feedback: ActionFeedback(), undo: stack)

        #expect(a.showOutcomeRaw == "too_soon")
        #expect(stack.entries.first?.rows.first?.priorShowOutcomeRaw == "not_a_fit")
    }

    // Nothing to do means nothing said and nothing recorded, rather than a banner claiming an action.
    @Test func anEmptyNightChangesNothing() throws {
        let ctx = try context()
        let feedback = ActionFeedback()
        let stack = QueueUndoStack()

        ProspectMutations.dismissAll([], reason: .tooSoon, dateLabel: "Jul 24",
                                     prospects: [], context: ctx, feedback: feedback, undo: stack)

        #expect(feedback.message == nil)
        #expect(stack.canUndo == false)
    }
}

// The words the undo banner says after a night comes back. Its own suite because the interesting case is
// the PARTIAL one: since #1134 the store and the visible stage move independently, so five shows coming
// back and three coming back look identical on screen unless the sentence says which happened (#1415).
@Suite("What an undone night says (#1500)")
struct BulkUndoCopyTests {
    @Test func awholeNightNamesTheCountAndTheStagePillItWentBackTo() {
        #expect(ActionAck.undoRestoredNight(count: 5, priorStatuses: [.new, .new])
                == "5 shows are back in Scout")
    }

    // Rows that came from different stages cannot all be pointed at one pill, so it stops naming one
    // rather than naming the wrong one.
    @Test func amixedNightDoesNotClaimOnePill() {
        #expect(ActionAck.undoRestoredNight(count: 2, priorStatuses: [.new, .queued])
                == "2 shows are back in your queue")
    }

    // The honest partial. It says what came back AND what did not, because the shows that moved on are
    // still dismissed and Dan has no other way to find that out.
    @Test func apartialRestoreSaysWhatDidNotComeBack() {
        #expect(ActionAck.undoRestoredPartOfNight(restored: 3, missed: 2, priorStatuses: [.new])
                == "3 shows are back in Scout. The other 2 had already moved on.")
    }

    @Test func anightThatEntirelyMovedOnSaysSoRatherThanNothing() {
        #expect(ActionAck.undoSkippedNight(count: 5)
                == "Those 5 shows had already moved on, so there was nothing to undo")
    }
}
