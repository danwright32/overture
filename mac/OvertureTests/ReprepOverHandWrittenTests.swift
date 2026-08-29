import Testing
import Foundation
import SwiftData

// #2007, decision 2 (Dan, 2026-08-03): re-prep IS offered on a draft he wrote himself, and it confirms
// before replacing hand-written text, because clobbering text he typed is the one unrecoverable outcome
// on this path.
//
// #2014: the BULK re-prep has no per-show confirm and never will, because a dialog per row is not a
// bulk action. Instead it never asks a Prep run to REDRAFT text Dan wrote: the destructive half is
// withheld, the safe half (finding contacts) still happens, and the acknowledgement names how many were
// left alone. Losing hand-written words is the one unrecoverable outcome on this path, and
// `originalDraftBody` is only populated when an AI draft is EDITED, so a wholly hand-written draft
// leaves nothing to fall back to.
@MainActor
@Suite("Re-prepping over a hand-written draft (#2007)")
struct ReprepOverHandWrittenTests {
    private func prospect() -> Prospect {
        Prospect(naturalKey: "k", groupName: "Bargemusic", discipline: "classical", venue: "Boathouse",
                 performanceDate: "2026-11-14", sourceListingURL: nil,
                 priorRelationship: "booked", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - What is confirmed, and why

    @Test func redraftingHandWrittenTextAsksFirstAndSaysWhatItWillReplace() {
        #expect(ReprepRequest.confirmation(mode: .draftOnly, writtenByDan: true,
                                           lastServedAt: nil, now: now)
                == "This replaces the email you wrote yourself with an AI draft. Replace it?")
    }

    // Finding contacts never touches the text, so there is nothing to warn about.
    @Test func findingContactsOnlyNeedsNoConfirmationOnHandWrittenText() {
        #expect(ReprepRequest.confirmation(mode: .contactsOnly, writtenByDan: true,
                                           lastServedAt: nil, now: now) == nil)
    }

    // The hand-written warning outranks the cooldown one: losing his own words is the worse outcome, and
    // two alerts in a row for one click is not a warning, it is a habit of clicking through.
    @Test func theHandWrittenWarningWinsOverTheCooldownWarning() {
        #expect(ReprepRequest.confirmation(mode: .both, writtenByDan: true,
                                           lastServedAt: now.addingTimeInterval(-60), now: now)
                == "This replaces the email you wrote yourself with an AI draft. Replace it?")
    }

    @Test func anAiDraftInsideTheCooldownStillAsksTheCooldownQuestion() {
        #expect(ReprepRequest.confirmation(mode: .draftOnly, writtenByDan: false,
                                           lastServedAt: now.addingTimeInterval(-60), now: now)
                == "This was re-prepped just now. Redo it anyway?")
    }

    @Test func anOrdinaryRedraftAsksNothing() {
        #expect(ReprepRequest.confirmation(mode: .draftOnly, writtenByDan: false,
                                           lastServedAt: nil, now: now) == nil)
    }

    // MARK: - What happens once he confirms

    // Having confirmed, the redraft has to actually LAND. The marker is what makes a Prep run refuse to
    // overwrite this text, so asking for an AI draft and leaving the marker in place would spend a run
    // whose result is then thrown away: a request that looks granted and silently does nothing.
    @Test func askingForARedraftReleasesTheTextToTheRun() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")

        ReprepRequest.apply(.draftOnly, to: p)

        #expect(p.reprepDraftRequested)
        #expect(p.draftWrittenByDan == false)
    }

    // Contacts-only never touches the words, so the text stays his and stays protected.
    @Test func askingOnlyForContactsLeavesTheTextHisAndStillProtected() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")

        ReprepRequest.apply(.contactsOnly, to: p)

        #expect(p.reprepContactsRequested)
        #expect(p.draftWrittenByDan)
    }

    // A draft request the send gate REFUSES (something has already gone out under this body) must not
    // release the text either: nothing is going to redraft it, so dropping the protection would leave the
    // next unrelated run free to overwrite words he wrote.
    @Test func aRefusedRedraftLeavesTheProtectionInPlace() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")
        p.sentAt = now

        ReprepRequest.apply(.both, to: p)

        #expect(p.reprepDraftRequested == false)
        #expect(p.draftWrittenByDan)
    }

    // MARK: - #2014: the bulk sweep never redrafts his own words

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func drafted(_ ctx: ModelContext, key: String, writtenByDan: Bool) -> Prospect {
        let p = prospect()
        p.naturalKey = key
        p.draftSubject = "s"
        p.draftBody = "b"
        p.status = .drafted
        p.draftWrittenByDan = writtenByDan
        ctx.insert(p)
        return p
    }

    // THE FAILURE PATH the issue asks for: a mixed batch, and his own text is not queued for replacement.
    @Test func aBulkRedraftOverAMixedBatchLeavesHandWrittenTextAlone() throws {
        let ctx = try context()
        let his = drafted(ctx, key: "his", writtenByDan: true)
        let ai = drafted(ctx, key: "ai", writtenByDan: false)

        ProspectMutations.bulkReprep(.draftOnly, prospects: [his, ai], context: ctx,
                                     feedback: ActionFeedback(), now: now)

        #expect(ai.reprepDraftRequested)
        #expect(!his.reprepDraftRequested, "the bulk sweep must never queue his own words for replacement")
        #expect(his.draftWrittenByDan, "and must not release the marker that protects them")
    }

    // The SAFE half still happens. Withholding contacts too would make the protection cost him something
    // he never asked to give up, and finding contacts does not touch the text at all.
    @Test func aBulkRedraftAndContactsStillFindsContactsForHisOwnDraft() throws {
        let ctx = try context()
        let his = drafted(ctx, key: "his", writtenByDan: true)

        ProspectMutations.bulkReprep(.both, prospects: [his], context: ctx,
                                     feedback: ActionFeedback(), now: now)

        #expect(his.reprepContactsRequested)
        #expect(!his.reprepDraftRequested)
    }

    // Contacts-only is untouched by any of this: it was never the destructive mode.
    @Test func aBulkContactHuntTreatsHisDraftLikeAnyOther() throws {
        let ctx = try context()
        let his = drafted(ctx, key: "his", writtenByDan: true)

        ProspectMutations.bulkReprep(.contactsOnly, prospects: [his], context: ctx,
                                     feedback: ActionFeedback(), now: now)

        #expect(his.reprepContactsRequested)
    }

    // And it SAYS so. Silently doing less than the button offered is its own defect: the count in the
    // confirmation was the only signal before, and a count cannot say what it is about to lose (L11).
    @Test func theAcknowledgementNamesTheEmailsItLeftAlone() {
        let said = ActionAck.bulkReprepQueued(mode: .draftOnly, total: 3, draftGrantedCount: 2,
                                              skippedCount: 0, handWrittenSpared: 1)
        #expect(said.contains("wrote yourself"))
        #expect(said.contains("1"))
    }

    @Test func nothingIsSaidAboutHandWrittenDraftsWhenThereWereNone() {
        let said = ActionAck.bulkReprepQueued(mode: .draftOnly, total: 3, draftGrantedCount: 3,
                                              skippedCount: 0, handWrittenSpared: 0)
        #expect(!said.contains("wrote yourself"))
    }

}
