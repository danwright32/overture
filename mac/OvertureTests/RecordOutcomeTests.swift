import Testing
import Foundation
import SwiftData

// #2395, phase 2 of docs/plans/2026-08-09-one-outcome-vocabulary.md: every menu that ends a show writes
// through ONE mutation, so the dismiss menu, the close-out menu on the reached-out row, the full card's
// "Mark..." menu and Follow-ups' "Not this one" cannot each record the ending slightly differently.
//
// The guard this adds beyond the menus themselves is the point: a menu offering only what is possible is
// a promise about a screen, and the write path has to keep that promise even when a caller gets it wrong,
// because an impossible ending recorded once is indistinguishable afterwards from one Dan chose.
@MainActor
@Suite("Recording a show's outcome (#2395)")
struct RecordOutcomeTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, key: String = "k",
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Orchestra of St Luke's", discipline: "music",
                         venue: "V", performanceDate: "2026-11-18", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        ctx.insert(p)
        return p
    }

    private func pitched(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = show(ctx, key: key, status: .contacted)
        p.sentAt = Date()
        let r = Recipient(id: "a@b.com", email: "a@b.com", provenance: .manual)
        r.sendState = .sent
        r.sentAt = Date()
        r.prospect = p
        ctx.insert(r)
        return p
    }

    // MARK: the never-pitched half

    // A show nothing was sent to leaves the queue when it ends, which is what dismissing means, and the
    // exit has to be dated or the drop-off can be counted but never placed in a year (#16).
    @Test func aNeverPitchedEndingDismissesTheShowAndDatesTheExit() throws {
        let ctx = try context()
        let p = show(ctx)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .hadPaidWork, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(ok)
        #expect(p.showOutcome == .hadPaidWork)
        #expect(p.status == .dismissed)
        #expect(p.dismissedAt != nil)
    }

    // MARK: the pitched half

    // A pitch that ended is NOT a dismissal. It went out, it got an answer or failed to, and it leaves the
    // reached-out stage because it now carries an ending, not because it was cut from the queue. Marking it
    // dismissed would file a real pitch among the shows Dan never sent to.
    @Test func aPitchedEndingDoesNotDismissTheShow() throws {
        let ctx = try context()
        let p = pitched(ctx)

        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNotNow, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())

        #expect(p.showOutcome == .theySaidNotNow)
        #expect(p.status == .contacted)
        #expect(p.dismissedAt == nil)
    }

    // A booking Dan records by hand has to say it was his call, or the next Downbeat reconcile claims the
    // same show and silently moves it from the manual half of the booking split to the automatic one.
    @Test func aBookingIsRecordedAsDansOwnCall() throws {
        let ctx = try context()
        let p = pitched(ctx)

        _ = ProspectMutations.recordOutcome(QueueItem(p), .booked, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())

        #expect(p.showOutcome == .booked)
        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.manual.rawValue)
    }

    // MARK: no impossible ending, enforced where it is written

    // The menus offer only the half that is possible, and this is the same promise kept one layer down. A
    // never-pitched reason on a show Dan already emailed would claim he never sent it.
    @Test func aNeverPitchedEndingIsRefusedOnAShowThatWasPitched() throws {
        let ctx = try context()
        let p = pitched(ctx)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .dateConflict, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(!ok)
        #expect(p.showOutcome == nil)
    }

    @Test func aPitchedEndingIsRefusedOnAShowNothingWasSentTo() throws {
        let ctx = try context()
        let p = show(ctx)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .neverHeardBack, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(!ok)
        #expect(p.showOutcome == nil)
    }

    // Overture's own two are not decisions, so no menu offers them and no hand can record them. `wentBy`
    // in particular is a fact about the calendar and must never read as a judgement Dan made.
    @Test func overturesOwnTwoCannotBeRecordedByHand() throws {
        let ctx = try context()
        for (i, outcome) in [ShowOutcome.wentBy, .tooFar].enumerated() {
            let p = show(ctx, key: "k\(i)")
            let ok = ProspectMutations.recordOutcome(QueueItem(p), outcome, prospects: [p],
                                                     context: ctx, feedback: ActionFeedback())
            #expect(!ok)
            #expect(p.showOutcome == nil)
        }
    }

    // A refusal has to SAY so. Silently doing nothing on a control Dan pressed is the worst of the three
    // outcomes: the row stays as it was and he has no way to tell that from a write that landed.
    @Test func arefusalTellsDanRatherThanFailingQuietly() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let feedback = ActionFeedback()

        _ = ProspectMutations.recordOutcome(QueueItem(p), .dateConflict, prospects: [p],
                                            context: ctx, feedback: feedback)

        #expect(feedback.message != nil)
    }

    // MARK: what Dan is told

    // The acknowledgment names the outcome back, because the row it was pressed on leaves the stage
    // immediately and a banner that only said "Saved" would be the sole evidence anything happened.
    @Test func theAcknowledgmentNamesTheOutcomeAndTheOrg() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let feedback = ActionFeedback()

        _ = ProspectMutations.recordOutcome(QueueItem(p), .turnedThemDown, prospects: [p],
                                            context: ctx, feedback: feedback)

        let said = feedback.message ?? ""
        #expect(said.contains("Orchestra of St Luke's"))
        #expect(said.lowercased().contains("turned them down"))
    }

    // Every value Dan can pick has to have words for the moment after he picks it. A missing line would
    // leave the one control whose row vanishes with nothing to show it worked.
    @Test func everyPickableOutcomeHasAnAcknowledgment() {
        for outcome in ShowOutcome.danCanChoose {
            let line = ShowOutcome.recordedLine(outcome, org: "Some Org")
            #expect(!line.isEmpty)
            #expect(line.contains("Some Org"))
        }
    }

    // No two acknowledgments may read the same, for the reason no two labels may: two endings described
    // in one sentence read as one ending.
    @Test func noTwoAcknowledgmentsReadTheSame() {
        let lines = ShowOutcome.danCanChoose.map { ShowOutcome.recordedLine($0, org: "Org") }
        #expect(Set(lines).count == lines.count)
    }

    // MARK: taking an ending back

    // The capability the old "In conversation" item actually provided. It was never an ending, it CLEARED
    // one, so replacing that menu with a list of endings has to keep a way back or a mis-pressed close-out
    // is unreachable from the card Dan is standing on.
    @Test func anEndingCanBeTakenBackAndTheShowReadsOpenAgain() throws {
        let ctx = try context()
        let p = pitched(ctx)
        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNo, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())
        #expect(p.showOutcome == .theySaidNo)

        let ok = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx,
                                                 feedback: ActionFeedback())

        #expect(ok)
        #expect(p.showOutcome == nil)
    }

    // #2396: recording an ending writes the SHOW and nothing else, so the contacts have nothing to clear.
    // Asserted on both sides of the round trip, because the earlier version of this wrote a copy onto every
    // contact and a reader that still expected one would fail silently rather than loudly.
    @Test func theContactsAreNeverTouchedByAnEnding() throws {
        let ctx = try context()
        let p = pitched(ctx)
        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNotNow, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())

        #expect(p.recipients.allSatisfy { $0.resolution == nil })
        #expect(p.performanceStatus == .lostDoorOpen, "read off the show's own ending")

        _ = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx,
                                            feedback: ActionFeedback())

        #expect(p.recipients.allSatisfy { $0.resolution == nil })
        #expect(p.performanceStatus == .active)
    }

    // Reopening a show that never ended does nothing and says nothing, rather than announcing an action
    // that did not happen.
    @Test func reopeningAShowWithNoEndingChangesNothing() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let feedback = ActionFeedback()

        let ok = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx,
                                                 feedback: feedback)

        #expect(!ok)
        #expect(feedback.message == nil)
    }

    // It names the ending being removed. The card shows several facts at once, so "Reopened" alone would
    // not say which one went.
    @Test func theReopenAcknowledgmentNamesWhatWasRemoved() throws {
        let ctx = try context()
        let p = pitched(ctx)
        _ = ProspectMutations.recordOutcome(QueueItem(p), .neverHeardBack, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())
        let feedback = ActionFeedback()

        _ = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        let said = feedback.message ?? ""
        #expect(said.contains("Orchestra of St Luke's"))
        #expect(said.contains("Never heard back"))
    }

    // MARK: undoing a close out (#3566)

    // Dan, 2026-09-05: "I'm on the reached out page and I clicked close this out on a show. then I
    // clicked cmd+z and nothing happened. it didn't come back."
    //
    // Close out was never in scope when undo was narrowed to keep and dismiss (his call, 2026-07-23),
    // and what changed since is that close out MOVED onto the row he stands on (#2112 / #2224 / #2710).
    // It now sits beside actions that are undoable with nothing to tell them apart from the keyboard.
    // His call, 2026-09-16: Cmd+Z, the same as keep and dismiss, rather than a separate control.
    @Test func closingAPitchOutRecordsAnUndoEntryNamingTheEnding() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let undo = QueueUndoStack()

        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNotNow, prospects: [p],
                                            context: ctx, feedback: ActionFeedback(), undo: undo)

        #expect(undo.canUndo)
        #expect(undo.undoMenuTitle == "Undo Close out: Orchestra of St Luke's")
    }

    // The stamp goes back with the ending, and that is not tidiness. #2915 records `showOutcomeAt` so a
    // reply arriving AFTERWARDS can be told from the reply Dan already had in hand when he closed this.
    // Left behind by an undo, it dates an ending that no longer exists, and every later comparison is
    // against a moment nothing on the row can explain.
    @Test func undoingACloseOutTakesBackTheEndingAndItsStamp() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let undo = QueueUndoStack()
        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNotNow, prospects: [p],
                                            context: ctx, feedback: ActionFeedback(), undo: undo)
        #expect(p.showOutcomeAt != nil)

        let entry = try #require(undo.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx))

        #expect(p.showOutcome == nil)
        #expect(p.showOutcomeAt == nil)
        #expect(p.status == .contacted)
    }

    // A close out that REPLACES an earlier ending must restore that earlier one, not clear the field.
    // The entry holds what was there rather than an assumed inverse, which is the same reason
    // `priorDismissedAt` is recorded rather than cleared.
    @Test func undoingACloseOutOverAnEarlierEndingRestoresTheEarlierOne() throws {
        let ctx = try context()
        let p = pitched(ctx)
        _ = ProspectMutations.recordOutcome(QueueItem(p), .neverHeardBack, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())
        let undo = QueueUndoStack()

        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNotNow, prospects: [p],
                                            context: ctx, feedback: ActionFeedback(), undo: undo)
        let entry = try #require(undo.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx))

        #expect(p.showOutcome == .neverHeardBack)
        #expect(p.showOutcomeAt != nil)
    }

    // THE GUARD, and it exists because the first version of #3566 wired ONE of three call sites.
    //
    // The issue named `FollowUpsView` as the Reached Out page's handler and that was taken at face
    // value. It is a call site, but it is not the one Dan pressed: the Reached Out row's close out is
    // `QueueView.closeOut(_:as:)`, and the full card's "Mark..." menu is a third in
    // `ProspectRowFactory`. Two of the three went out unwired, and every test passed, because a test
    // that drives the mutation directly hands it a stack itself and can never notice a VIEW that does
    // not. It was caught by closing a show out in the running app and reading the Edit menu, which
    // still named the previous action.
    //
    // Derived from the code rather than listed, because a hand written list checks only what somebody
    // remembered to add and the whole defect here is a call site nobody added (L96, L30).
    @Test func everyCloseOutCallSiteHandsInTheUndoStack() {
        let call = "ProspectMutations.recordOutcome("
        let candidates = AppSourceWalk.appFiles().filter { $0.text.contains(call) }
        #expect(candidates.count >= 3,
                "found \(candidates.count) files calling recordOutcome, too few to be scanning the app (L98)")

        var unwired: [String] = []
        for file in candidates {
            for piece in file.text.components(separatedBy: call).dropFirst() {
                // The call's own argument list, which ends at the first close paren that balances the
                // one the call opened. Read rather than a fixed character count, because a window of N
                // characters stops containing the call the day an argument is added (L518).
                var depth = 1
                var arguments = ""
                for character in piece {
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1; if depth == 0 { break } }
                    arguments.append(character)
                }
                if !arguments.contains("undo:") { unwired.append(file.name) }
            }
        }
        let named = unwired.sorted().joined(separator: ", ")
        #expect(unwired.isEmpty,
                "these close out a show without handing in the undo stack, so Cmd+Z after the press reaches an older unrelated action instead (#3566): \(named)")
    }

    // The never-pitched half goes down the dismiss path, and that path already records. Asserted so the
    // two halves of `recordOutcome` cannot drift into one recording and the other not, which from the
    // keyboard would look like Cmd+Z working on some endings and not others (L11).
    @Test func aNeverPitchedEndingIsUndoableToo() throws {
        let ctx = try context()
        let p = show(ctx, status: .queued)
        let undo = QueueUndoStack()

        _ = ProspectMutations.recordOutcome(QueueItem(p), .hadPaidWork, prospects: [p],
                                            context: ctx, feedback: ActionFeedback(), undo: undo)
        let entry = try #require(undo.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx))

        #expect(p.status == .queued)
        #expect(p.showOutcome == nil)
        #expect(p.dismissedAt == nil)
    }
}
