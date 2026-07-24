import Testing
import Foundation
import SwiftData
@testable import Overture

// Performing an undo (#1414): putting a row back the way it was, and refusing to when it has moved.
//
// The precondition here is what replaced the "wall" once the feature narrowed to keep and dismiss.
// Rather than keeping a list of actions that clear the stack, every entry checks the row it describes
// at the moment Cmd+Z is pressed. That one rule covers all of it at once: a background writer (the
// reconcile tick, a scout import, a retirement sweep), a later action of Dan's, a send that made the
// show contacted, and a row that no longer exists at all.
@MainActor
@Suite("Performing a queue undo (#1414)")
struct QueueUndoApplyTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, status: ReviewStatus = .new) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "The Music Shop",
                                          performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "The Music Shop", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // MARK: - Recording

    // The entry is built from the row itself, before and after, rather than from an assumed inverse.
    @Test func recordingCapturesWhereTheRowWasAndWhereItLanded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status

        p.markDismissed(reason: .notInterested)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorDismissReasonRaw: nil, priorDismissedAt: nil)

        #expect(entry.naturalKey == p.naturalKey)
        #expect(entry.groupName == "The Music Shop")
        #expect(entry.priorStatus == .queued)
        #expect(entry.resultingStatus == .dismissed)
        #expect(entry.resultingDismissReasonRaw == DismissReason.notInterested.rawValue)
    }

    // MARK: - Applying

    // Undo restores the CAPTURED status, not a hardcoded "back to the queue". A show dismissed while
    // it was contacted must come back contacted, or undoing would quietly re-offer a group Dan has
    // already emailed as though it were a fresh lead.
    @Test func undoRestoresTheStatusTheRowActuallyCameFrom() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .contacted)
        let priorStatus = p.status

        p.markDismissed(reason: .notInterested)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorDismissReasonRaw: nil, priorDismissedAt: nil)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])))
        #expect(p.status == .contacted)
        #expect(p.dismissReasonRaw == nil)
        #expect(p.dismissedAt == nil)
    }

    // The exit-date fix, and the reason it had to land in this change rather than after it.
    //
    // `markDismissed` stamps `dismissedAt` only when it is nil, so a show dismissed twice keeps its
    // FIRST exit date. Undoing a RESTORE therefore re-dismisses the show, and going back through
    // `markDismissed` would stamp TODAY over that original date, silently corrupting the #1403 funnel
    // data (which counts when a show left the queue). Applying the captured snapshot puts the real
    // date back instead of re-deriving one.
    @Test func undoingARestorePutsTheOriginalExitDateBackNotToday() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .new)
        let trueExit = Date(timeIntervalSince1970: 1_770_000_000)
        p.markDismissed(reason: .tooFar, at: trueExit)
        let priorStatus = p.status, priorReason = p.dismissReasonRaw, priorExit = p.dismissedAt

        // Dan restores it from the Archive, which clears the exit date...
        DismissedProspects.restore(p)
        let entry = QueueUndoEntry(recording: "Restore", on: p, priorStatus: priorStatus,
                                   priorDismissReasonRaw: priorReason, priorDismissedAt: priorExit)

        // ...and then takes that back.
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])))
        #expect(p.status == .dismissed)
        #expect(p.dismissedAt == trueExit)   // NOT today
        #expect(p.dismissReasonRaw == DismissReason.tooFar.rawValue)
    }

    // MARK: - Refusing to apply

    // A background writer moved the row after the action. Those writers are invisible to undo by
    // design (they neither push nor clear the stack, so Cmd+Z never goes dead through no action of
    // Dan's), which is exactly why the check has to happen here, at the moment of undoing.
    @Test func aRowABackgroundSweepMovedIsSkippedRatherThanOverwritten() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status

        p.markDismissed(reason: .notInterested)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorDismissReasonRaw: nil, priorDismissedAt: nil)

        // A retirement sweep re-labels the cut between the action and the undo.
        p.markDismissed(reason: .wentBy)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])) == false)
        #expect(p.dismissReasonRaw == DismissReason.wentBy.rawValue)   // the newer reason survives
        #expect(p.status == .dismissed)                                // and nothing was restored
    }

    // A send made the show contacted after the dismiss. Restoring would drag it back out of a stage it
    // legitimately reached, so it is skipped.
    @Test func aRowASendMovedOnIsSkipped() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status

        p.markDismissed(reason: .notInterested)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorDismissReasonRaw: nil, priorDismissedAt: nil)

        p.clearDismissal(to: .contacted)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])) == false)
        #expect(p.status == .contacted)
    }

    // The row is gone entirely. Rows really are deleted at runtime (NaturalKeyVenueMigration), which is
    // why an entry holds a key rather than the object, and why the lookup can legitimately come back
    // empty. Undo says no rather than crashing or inventing a row.
    @Test func aRowThatNoLongerExistsIsSkipped() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status
        p.markDismissed(reason: .notInterested)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorDismissReasonRaw: nil, priorDismissedAt: nil)

        #expect(QueueUndo.apply(entry, to: nil, in: ctx, export: (bookings: [], blockedDates: [])) == false)
    }

    // An undo already performed cannot be performed twice: the second attempt finds the row in its
    // restored state, which is not the state the action left it in. Belt and braces on top of the
    // stack discarding a taken entry, because the same action can reach here through a repeat keypress.
    @Test func undoingTheSameEntryTwiceDoesNothingTheSecondTime() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status
        p.markDismissed(reason: .notInterested)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorDismissReasonRaw: nil, priorDismissedAt: nil)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])))
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])) == false)
        #expect(p.status == .queued)
    }

    // MARK: - One restore implementation (#1414's consolidation)

    // Archive's Restore button and Cmd+Z both go through DismissedProspects.restore now, so they cannot
    // drift apart. They pass DIFFERENT targets on purpose: the button returns a show to the queue as an
    // undecided candidate, which is what Restore has always meant and all it can mean for a show
    // dismissed in an earlier session (nothing records what that show was before). Undo passes the
    // status it captured moments ago.
    @Test func restoreDefaultsToTheQueueForTheArchiveButton() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .contacted)
        p.markDismissed(reason: .notInterested)

        DismissedProspects.restore(p)

        #expect(p.status == .new)
        #expect(p.dismissedAt == nil)   // #16: a live show has no exit date
        #expect(p.dismissReasonRaw == nil)
    }

    @Test func restoreCanBeAskedForAParticularStatus() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .contacted)
        p.markDismissed(reason: .notInterested)

        DismissedProspects.restore(p, to: .contacted)

        #expect(p.status == .contacted)
        #expect(p.dismissedAt == nil)
    }

    // MARK: - Which actions record at all

    // Dan's scope, and the reason recording is passed IN rather than done inside setStatus: that one
    // setter also drives approve, unapprove and skip-draft. Recording unconditionally there would
    // quietly make approving a draft undoable too, well past "I mostly just need this for keep/dismiss".

    @Test func keepRecordsAnEntryNamingTheAction() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .new)
        let stack = QueueUndoStack()

        ProspectMutations.setStatus(QueueItem(p), .queued, nil, prospects: [p], context: ctx,
                                    feedback: ActionFeedback(), undo: stack, undoLabel: "Keep")

        #expect(stack.canUndo)
        #expect(stack.undoMenuTitle == "Undo Keep: The Music Shop")
    }

    @Test func approvingRecordsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .drafted)
        let stack = QueueUndoStack()

        // The approve call site passes no stack at all, so nothing lands even though it is the same setter.
        ProspectMutations.setStatus(QueueItem(p), .approved, nil, prospects: [p], context: ctx,
                                    feedback: ActionFeedback())

        #expect(stack.canUndo == false)
    }

    // End to end through the real mutation: keep it, then put it back where it was.
    @Test func aRecordedKeepCanBeUndoneBackToWhereItStarted() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .new)
        let stack = QueueUndoStack()

        ProspectMutations.setStatus(QueueItem(p), .queued, nil, prospects: [p], context: ctx,
                                    feedback: ActionFeedback(), undo: stack, undoLabel: "Keep")
        #expect(p.status == .queued)

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])))
        #expect(p.status == .new)
    }
}

// The last wires (#1414), which none of the behaviour above can see: every rule stays green while the
// menu raises a request nothing answers, or keep and dismiss never hand the stack over at all.
@Suite("Undo recording and performing wiring (#1414)")
struct QueueUndoWiringGuardTests {
    private func source(_ rel: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(rel, file: file)
    }

    @Test func keepAndDismissHandTheStackOverAndNothingElseDoes() {
        let factory = source("Overture/UI/ProspectRowFactory.swift")
        #expect(!factory.isEmpty)
        #expect(factory.contains("undo: undoStack, undoLabel: \"Keep\""))
        #expect(factory.contains("offer: dayOffOffer, undo: undoStack"))
        // Approve, unapprove and skip-draft go through the same setter and must NOT record.
        #expect(factory.contains("undo: undoStack, undoLabel: \"Approve\"") == false)
        #expect(factory.contains("undo: undoStack, undoLabel: \"Skip\"") == false)
    }

    @Test func theMenuRaisesARequestAndTheWindowPerformsIt() {
        let app = source("Overture/App/OvertureApp.swift")
        let root = source("Overture/App/RootView.swift")
        #expect(app.contains("undoRequest.request()"))
        #expect(app.contains(".environment(undoRequest)"))
        #expect(root.contains("onChange(of: undoRequest.token)"))
        #expect(root.contains("performQueueUndo()"))
        #expect(root.contains("QueueUndo.apply(entry, to: model, in: context)"))
    }

    // The entry is taken off the stack BEFORE it is known to be applicable. A stale entry is spent
    // either way, and leaving it on would make every later Cmd+Z retry the same dead entry instead of
    // reaching the one behind it.
    @Test func aStaleEntryIsSpentRatherThanLeftBlockingTheOnesBehindIt() {
        let root = source("Overture/App/RootView.swift")
        #expect(root.contains("guard let entry = undoStack.takeTop() else { return }"))
    }

    // Archive's Restore button goes through the shared implementation, so it cannot drift from undo.
    @Test func archiveRestoreGoesThroughTheSharedImplementation() {
        let archive = source("Overture/UI/ArchiveView.swift")
        #expect(archive.contains("DismissedProspects.restore(model)"))
        #expect(archive.contains("model.clearDismissal(") == false)   // never its own copy
    }
}
