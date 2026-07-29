import Testing
import Foundation
import SwiftData
@testable import Overture

// #1500: one action that dismissed a whole night is ONE entry on the undo stack, so Cmd+Z brings the
// night back in one press rather than one press per card. That is the requirement in the issue, and it is
// the reason the entry stopped being strictly one row.
//
// The interesting half is the partial case. The night's rows are independent prospects, and anything can
// have moved one of them since (a scout re-scored it, a sweep took it, Dan acted on it again). Restoring
// none of them because one moved would punish Dan for something he did not do; restoring four and
// reporting five would be the silent half-undo #1473 exists to prevent. So it restores what it still can
// and reports exactly how much that was.
@MainActor
@Suite("Undoing a whole night at once (#1500)")
struct QueueUndoBatchTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func dismissedShow(_ ctx: ModelContext, _ key: String, reason: String = "too_soon") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Org \(key)", discipline: "music",
                         venue: "Stern Auditorium", performanceDate: "2026-07-24", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .dismissed)
        p.dismissReasonRaw = reason
        p.dismissedAt = Date(timeIntervalSince1970: 1_780_000_000)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func row(_ key: String, from priorStatus: ReviewStatus = .new,
                     reason: String = "too_soon") -> QueueUndoEntry.Row {
        QueueUndoEntry.Row(naturalKey: key, groupName: "Org \(key)",
                           priorStatus: priorStatus, priorDismissReasonRaw: nil, priorDismissedAt: nil, priorConflictClearedKey: nil,
                           resultingStatus: .dismissed, resultingDismissReasonRaw: reason)
    }

    // MARK: - The entry

    @Test func abatchCarriesEveryRowItTook() throws {
        let entry = try #require(QueueUndoEntry.batch(actionLabel: "Dismiss", label: "3 shows on Jul 24",
                                                      rows: [row("a"), row("b"), row("c")]))

        #expect(entry.rows.count == 3)
        #expect(entry.rows.map(\.naturalKey) == ["a", "b", "c"])
    }

    // The Edit menu names the NIGHT. "Undo Dismiss: Org a" would promise one show and give back three.
    @Test func theMenuTitleNamesTheNightRatherThanOneShow() throws {
        let stack = QueueUndoStack()
        stack.record(try #require(QueueUndoEntry.batch(actionLabel: "Dismiss", label: "3 shows on Jul 24",
                                                       rows: [row("a"), row("b"), row("c")])))

        #expect(stack.undoMenuTitle == "Undo Dismiss: 3 shows on Jul 24")
    }

    // A batch of nothing is not an entry. An empty one would sit on the stack and swallow the next Cmd+Z
    // while appearing to do something.
    @Test func abatchOfNoRowsIsNotRecordable() {
        #expect(QueueUndoEntry.batch(actionLabel: "Dismiss", label: "0 shows on Jul 24", rows: []) == nil)
    }

    // MARK: - Applying it

    @Test func onePressBringsTheWholeNightBack() throws {
        let ctx = try context()
        let a = dismissedShow(ctx, "a")
        let b = dismissedShow(ctx, "b")
        let entry = try #require(QueueUndoEntry.batch(actionLabel: "Dismiss", label: "2 shows on Jul 24",
                                                      rows: [row("a"), row("b")]))

        let outcome = QueueUndo.apply(entry, resolving: { key in [a, b].first { $0.naturalKey == key } },
                                      in: ctx)

        #expect(outcome.restored == 2)
        #expect(outcome.total == 2)
        #expect(a.status == .new)
        #expect(b.status == .new)
        #expect(a.dismissReasonRaw == nil)
        #expect(a.dismissedAt == nil)      // a show back in the queue has no exit date (#16)
    }

    // THE case this shape exists for: one row moved on under Dan. The rest still come back, and the
    // outcome says how many did, so the banner can tell him the truth rather than "5 shows are back".
    @Test func arowThatMovedOnIsLeftAloneAndTheRestStillComeBack() throws {
        let ctx = try context()
        let a = dismissedShow(ctx, "a")
        let b = dismissedShow(ctx, "b")
        b.status = .contacted             // a send moved it since the dismissal
        try ctx.save()
        let entry = try #require(QueueUndoEntry.batch(actionLabel: "Dismiss", label: "2 shows on Jul 24",
                                                      rows: [row("a"), row("b")]))

        let outcome = QueueUndo.apply(entry, resolving: { key in [a, b].first { $0.naturalKey == key } },
                                      in: ctx)

        #expect(outcome.restored == 1)
        #expect(outcome.total == 2)
        #expect(outcome.isPartial)
        #expect(a.status == .new)
        #expect(b.status == .contacted)   // untouched: undo never clobbers something newer
    }

    // A row deleted at runtime (NaturalKeyVenueMigration) is an ordinary outcome, not an error, which is
    // why an entry holds keys rather than objects.
    @Test func arowThatIsGoneIsCountedNotCrashedOn() throws {
        let ctx = try context()
        let a = dismissedShow(ctx, "a")
        let entry = try #require(QueueUndoEntry.batch(actionLabel: "Dismiss", label: "2 shows on Jul 24",
                                                      rows: [row("a"), row("gone")]))

        let outcome = QueueUndo.apply(entry, resolving: { key in key == "a" ? a : nil }, in: ctx)

        #expect(outcome.restored == 1)
        #expect(outcome.total == 2)
    }

    // Every row having moved on is the whole entry going stale, and the caller has to be able to tell that
    // apart from a working undo (#1415): the store changes and the screen does not.
    @Test func anEntryWhoseRowsAllMovedOnRestoresNothing() throws {
        let ctx = try context()
        let a = dismissedShow(ctx, "a", reason: "not_interested")   // re-labelled since
        let entry = try #require(QueueUndoEntry.batch(actionLabel: "Dismiss", label: "1 show on Jul 24",
                                                      rows: [row("a")]))

        let outcome = QueueUndo.apply(entry, resolving: { _ in a }, in: ctx)

        #expect(outcome.restored == 0)
        #expect(outcome.didAnything == false)
        #expect(a.status == .dismissed)
    }

    // The single-row entry every existing caller records still behaves exactly as it did: one row in, one
    // row back, the old Bool answer.
    @Test func asingleRowEntryIsUnchanged() throws {
        let ctx = try context()
        let a = dismissedShow(ctx, "a")
        let entry = QueueUndoEntry(naturalKey: "a", groupName: "Org a", actionLabel: "Dismiss",
                                   priorStatus: .queued, priorDismissReasonRaw: nil, priorDismissedAt: nil, priorConflictClearedKey: nil,
                                   resultingStatus: .dismissed, resultingDismissReasonRaw: "too_soon")

        #expect(QueueUndo.apply(entry, to: a, in: ctx))
        #expect(a.status == .queued)
        #expect(entry.rows.count == 1)
        #expect(entry.naturalKey == "a")
    }
}
