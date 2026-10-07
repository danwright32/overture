import Testing
import Foundation
import SwiftData

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
                         sourceListingURL: nil, priorRelationship: "none",
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

        p.markDismissed(reason: .notAFit)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil, priorConflictClearedKey: nil)

        #expect(entry.naturalKey == p.naturalKey)
        #expect(entry.groupName == "The Music Shop")
        #expect(entry.priorStatus == .queued)
        #expect(entry.resultingStatus == .dismissed)
        #expect(entry.resultingShowOutcomeRaw == ShowOutcome.notAFit.rawValue)
    }

    // MARK: - Applying

    // Undo restores the CAPTURED status, not a hardcoded "back to the queue". A show dismissed while
    // it was contacted must come back contacted, or undoing would quietly re-offer a group Dan has
    // already emailed as though it were a fresh lead.
    @Test func undoRestoresTheStatusTheRowActuallyCameFrom() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .contacted)
        let priorStatus = p.status

        p.markDismissed(reason: .notAFit)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil, priorConflictClearedKey: nil)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)))
        #expect(p.status == .contacted)
        #expect(p.showOutcomeRaw == nil)
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
        let priorStatus = p.status, priorReason = p.showOutcomeRaw, priorExit = p.dismissedAt

        // Dan restores it from the Archive, which clears the exit date...
        DismissedProspects.restore(p)
        let entry = QueueUndoEntry(recording: "Restore", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: priorReason, priorShowOutcomeAt: nil, priorDismissedAt: priorExit, priorConflictClearedKey: nil)

        // ...and then takes that back.
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)))
        #expect(p.status == .dismissed)
        #expect(p.dismissedAt == trueExit)   // NOT today
        #expect(p.showOutcomeRaw == ShowOutcome.tooFar.rawValue)
    }

    // MARK: - Refusing to apply

    // A background writer moved the row after the action. Those writers are invisible to undo by
    // design (they neither push nor clear the stack, so Cmd+Z never goes dead through no action of
    // Dan's), which is exactly why the check has to happen here, at the moment of undoing.
    @Test func aRowABackgroundSweepMovedIsSkippedRatherThanOverwritten() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status

        p.markDismissed(reason: .notAFit)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil, priorConflictClearedKey: nil)

        // A retirement sweep re-labels the cut between the action and the undo.
        p.markDismissed(reason: .wentBy)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)) == false)
        #expect(p.showOutcomeRaw == ShowOutcome.wentBy.rawValue)   // the newer reason survives
        #expect(p.status == .dismissed)                                // and nothing was restored
    }

    // A send made the show contacted after the dismiss. Restoring would drag it back out of a stage it
    // legitimately reached, so it is skipped.
    @Test func aRowASendMovedOnIsSkipped() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status

        p.markDismissed(reason: .notAFit)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil, priorConflictClearedKey: nil)

        p.clearDismissal(to: .contacted)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)) == false)
        #expect(p.status == .contacted)
    }

    // The row is gone entirely. Rows really are deleted at runtime (NaturalKeyVenueMigration), which is
    // why an entry holds a key rather than the object, and why the lookup can legitimately come back
    // empty. Undo says no rather than crashing or inventing a row.
    @Test func aRowThatNoLongerExistsIsSkipped() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status
        p.markDismissed(reason: .notAFit)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil, priorConflictClearedKey: nil)

        #expect(QueueUndo.apply(entry, to: nil, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)) == false)
    }

    // An undo already performed cannot be performed twice: the second attempt finds the row in its
    // restored state, which is not the state the action left it in. Belt and braces on top of the
    // stack discarding a taken entry, because the same action can reach here through a repeat keypress.
    @Test func undoingTheSameEntryTwiceDoesNothingTheSecondTime() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .queued)
        let priorStatus = p.status
        p.markDismissed(reason: .notAFit)
        let entry = QueueUndoEntry(recording: "Dismiss", on: p, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil, priorConflictClearedKey: nil)

        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)))
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)) == false)
        #expect(p.status == .queued)
    }

    // MARK: - Across a merge (#4532)

    // Cmd+Z used to find its show by natural key, and `naturalKey` is unique and REASSIGNED: a merge
    // deletes the loser and hands its key to the survivor. Undoing an action recorded on the loser then
    // found the SURVIVOR by that key, and when the survivor happened to sit where the action had left the
    // loser, it was rewritten with the loser's prior state, with nothing said (L145, L75, L15). The entry
    // now records the show's store identity, with the key as its witness, and resolves through the same
    // rule every row press uses (`ShowIdentity`, #4538).
    private func merged(_ ctx: ModelContext) throws -> (entry: QueueUndoEntry, loser: Prospect,
                                                        survivor: Prospect) {
        let loser = show(ctx, status: .queued)
        let survivor = Prospect(naturalKey: "survivor-key", groupName: "The Survivor", discipline: "music",
                                venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                                sourceListingURL: nil, priorRelationship: "none",
                                production: "self", profile: "strong", coverage: "likely_uncovered",
                                fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                                possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(survivor)
        try ctx.save()

        let priorStatus = loser.status
        loser.markDismissed(reason: .notAFit)
        let entry = QueueUndoEntry(recording: "Dismiss", on: loser, priorStatus: priorStatus,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil,
                                   priorConflictClearedKey: nil)
        // The survivor sits EXACTLY where the action left the loser, so the entry's own precondition
        // (`stillApplies`) cannot tell the two apart. Only the identity can.
        survivor.markDismissed(reason: .notAFit)
        try ctx.save()
        return (entry, loser, survivor)
    }

    // The positive control in the same fixture (L159): before the merge, the very same entry resolves
    // through the live rows and is undone. Without this, every refusal below could be a resolver that
    // finds nothing at all.
    @Test func anEntryResolvesThroughTheLiveRowsByIdentityBeforeAnyMerge() throws {
        let ctx = ModelContext(try container())
        let (entry, loser, survivor) = try merged(ctx)

        let outcome = QueueUndo.apply(entry, resolving: [survivor, loser], in: ctx,
                                      export: (bookings: [], blockedDates: [], health: .ok))

        #expect(outcome.restored == 1, "an unmerged entry was not undone, so the refusal tests prove nothing")
        #expect(outcome.refusals.isEmpty)
        #expect(loser.status == .queued)
        #expect(survivor.status == .dismissed, "undoing the loser's dismiss touched a different show")
    }

    @Test func undoingAnActionOnAMergedAwayShowLeavesTheSurvivorUntouched() throws {
        let ctx = ModelContext(try container())
        let (entry, loser, survivor) = try merged(ctx)
        let loserKey = loser.naturalKey

        // The merge: the loser goes, then the survivor adopts its key.
        ctx.delete(loser)
        try ctx.save()
        survivor.naturalKey = loserKey
        try ctx.save()

        let outcome = QueueUndo.apply(entry, resolving: [survivor], in: ctx,
                                      export: (bookings: [], blockedDates: [], health: .ok))

        #expect(survivor.status == .dismissed,
                Comment(rawValue: "Cmd+Z on a merged-away show's dismiss restored the SURVIVOR that adopted "
                        + "its key. A key lookup finds exactly one row with nothing to report, so the undo "
                        + "lands on a show Dan never acted on (#4532, L145, L75)."))
        #expect(survivor.showOutcomeRaw == ShowOutcome.notAFit.rawValue)
        #expect(!ctx.hasChanges, "the refused undo left an unsaved change behind")
        #expect(outcome.restored == 0)
        #expect(outcome.refusals == [.gone])
        #expect(QueueUndo.nothingUndoneSentence(for: entry, outcome: outcome)
                == ShowIdentity.Refusal.gone.undoSentence(org: "The Music Shop"))
    }

    // The survivor's OWN entry, after it adopted another key in the same merge. It is the same row, but
    // not the show the action was taken on, so it is refused as moved rather than undone.
    @Test func undoingAnActionOnAShowWhoseKeyMovedSinceIsRefusedAsMoved() throws {
        let ctx = ModelContext(try container())
        let (_, loser, survivor) = try merged(ctx)
        let entry = QueueUndoEntry(recording: "Dismiss", on: survivor, priorStatus: .queued,
                                   priorShowOutcomeRaw: nil, priorShowOutcomeAt: nil, priorDismissedAt: nil,
                                   priorConflictClearedKey: nil)
        let loserKey = loser.naturalKey
        ctx.delete(loser)
        try ctx.save()
        survivor.naturalKey = loserKey
        try ctx.save()

        let outcome = QueueUndo.apply(entry, resolving: [survivor], in: ctx,
                                      export: (bookings: [], blockedDates: [], health: .ok))

        #expect(survivor.status == .dismissed, "an undo recorded under the survivor's old key was applied anyway")
        #expect(outcome.refusals == [.reKeyed])
        #expect(QueueUndo.nothingUndoneSentence(for: entry, outcome: outcome)
                == ShowIdentity.Refusal.reKeyed.undoSentence(org: "The Survivor"))
    }

    // A row that simply moved on keeps its own sentence: the refusal sentences are for a row the identity
    // could not find, and saying "merged" about a show a send moved on would be a different untruth.
    @Test func aRowThatMovedOnStillSaysItMovedOn() throws {
        let ctx = ModelContext(try container())
        let (entry, loser, _) = try merged(ctx)
        loser.clearDismissal(to: .contacted)

        let outcome = QueueUndo.apply(entry, resolving: [loser], in: ctx,
                                      export: (bookings: [], blockedDates: [], health: .ok))

        #expect(outcome.refusals.isEmpty)
        #expect(QueueUndo.nothingUndoneSentence(for: entry, outcome: outcome)
                == ActionAck.undoSkipped(org: "The Music Shop"))
    }

    // Every cause has its own sentence, so a merged show and a show that was never saved cannot be told
    // to Dan in the same words (L11, L260).
    @Test func everyRefusalHasItsOwnUndoSentence() {
        let sentences = ShowIdentity.Refusal.allCases.map { $0.undoSentence(org: "The Music Shop") }
        #expect(Set(sentences).count == ShowIdentity.Refusal.allCases.count)
        #expect(sentences.allSatisfy { $0.contains("The Music Shop") })
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
        p.markDismissed(reason: .notAFit)

        DismissedProspects.restore(p)

        #expect(p.status == .new)
        #expect(p.dismissedAt == nil)   // #16: a live show has no exit date
        #expect(p.showOutcomeRaw == nil)
    }

    @Test func restoreCanBeAskedForAParticularStatus() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .contacted)
        p.markDismissed(reason: .notAFit)

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

        ProspectMutations.setStatus(QueueItem(p), .queued, nil, shows: [p], context: ctx,
                                    feedback: ActionFeedback(), undo: stack, undoLabel: "Keep")

        #expect(stack.canUndo)
        #expect(stack.undoMenuTitle == "Undo Keep: The Music Shop")
    }

    @Test func approvingRecordsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .drafted)
        let stack = QueueUndoStack()

        // The approve call site passes no stack at all, so nothing lands even though it is the same setter.
        ProspectMutations.setStatus(QueueItem(p), .approved, nil, shows: [p], context: ctx,
                                    feedback: ActionFeedback())

        #expect(stack.canUndo == false)
    }

    // End to end through the real mutation: keep it, then put it back where it was.
    @Test func aRecordedKeepCanBeUndoneBackToWhereItStarted() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .new)
        let stack = QueueUndoStack()

        ProspectMutations.setStatus(QueueItem(p), .queued, nil, shows: [p], context: ctx,
                                    feedback: ActionFeedback(), undo: stack, undoLabel: "Keep")
        #expect(p.status == .queued)

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [], health: .ok)))
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
        // #2726: the call and its trigger as ONE piece of code. Asserted separately, `performQueueUndo()`
        // was satisfied by the function's own declaration, so the window could have stopped calling it
        // entirely and this stayed green (L135).
        #expect(SourceGuardHelper.containsCode(
            ".onChange(of: undoRequest.token) { _, _ in performQueueUndo() }", in: root))
        // #1500: the entry can cover a whole night, so the window resolves every row it names rather than
        // one model it looked up itself.
        #expect(root.contains("QueueUndo.apply(entry, resolving:"))
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
