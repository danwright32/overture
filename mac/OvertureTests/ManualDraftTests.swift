import Testing
import Foundation
import SwiftData

// #2007: prepping a show BY HAND, with no AI run at all. The warmest shows (an annual booking Dan has
// shot five years running) are the ones an AI draft helps least and costs most, so there is a second
// route from a kept prospect to `.drafted` that spends nothing.
//
// The marker `draftWrittenByDan` is its own field rather than a reuse of `draftEditedByDan` (Dan's call,
// 2026-08-03): reporting has to be able to tell an email he WROTE from an AI draft he TWEAKED, and one
// flag cannot say both. These tests pin the marker and every reader that has to honour it.
@MainActor
@Suite("Manual draft")
struct ManualDraftTests {
    private func prospect(group: String = "Bargemusic", status: ReviewStatus = .queued) -> Prospect {
        Prospect(naturalKey: "\(group)|2026-11-14|Boathouse", groupName: group, discipline: "classical",
                 venue: "Boathouse", performanceDate: "2026-11-14", sourceListingURL: nil,
                 priorRelationship: "booked", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
    }

    @Test func writingByHandDraftsTheShowAndMarksItAsDansOwn() {
        let p = prospect()
        p.writeManualDraft(subject: "Your November dates", body: "Hi Olga, are the November dates set yet?")

        #expect(p.draftSubject == "Your November dates")
        #expect(p.draftBody == "Hi Olga, are the November dates set yet?")
        #expect(p.draftWrittenByDan)
        #expect(p.status == .drafted)
    }

    // No model call happened, so no model may be credited with the words. This is what keeps a
    // hand-written email out of the drafting trace and out of any per-model accounting.
    @Test func aHandWrittenDraftIsCreditedToNoModel() {
        let p = prospect()
        p.draftModel = "opus"   // a stale stamp from an earlier draft on this show
        p.writeManualDraft(subject: "s", body: "b")

        #expect(p.draftModel == nil)
        #expect(DraftTrace.label(for: p.draftModel) == nil)
    }

    // The voice-learning pair studies how Dan REVISES an AI draft. There is no AI draft here, so there
    // is no delta to learn from, and a snapshot of nothing would teach the drafter that his own words
    // were the model's.
    @Test func aHandWrittenDraftSnapshotsNoAiBaseline() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")

        #expect(p.originalDraftBody == nil)
        #expect(p.originalDraftSubject == nil)
    }

    // The marker is deliberately NOT `draftEditedByDan`: an email he wrote and an AI draft he tweaked
    // have to stay tellable apart, which is the whole reason it is its own field.
    @Test func writingByHandIsNotRecordedAsEditingAnAiDraft() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")

        #expect(p.draftEditedByDan == false)
    }

    // The queue promise: a hand-prepped show stops being prep work the instant it is drafted, exactly
    // as an AI-prepped one does, and shows up in the review count instead.
    @Test func savingAManualDraftMovesTheShowOutOfPrepAndIntoReview() {
        let p = prospect()
        #expect(PrepStatus.from(prospects: [p], lastRunStartedAt: nil, running: false).kept == 1)

        p.writeManualDraft(subject: "s", body: "b")
        let after = PrepStatus.from(prospects: [p], lastRunStartedAt: nil, running: false)

        #expect(after.kept == 0)
        #expect(after.drafted == 1)
    }

    // A hand-written draft is the one text on this path that cannot be regenerated, so a Prep run that
    // reaches this show (a re-prep, or a run Dan launched over the whole queue) must leave it alone. The
    // refusal has its own counter rather than borrowing "kept your edits", which would tell him a run
    // preserved an edit he never made.
    @Test func aPrepRunNeverOverwritesAHandWrittenDraft() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = prospect()
        p.writeManualDraft(subject: "Your November dates", body: "Hi Olga, are the November dates set yet?")
        p.reprepDraftRequested = true
        ctx.insert(p)
        try ctx.save()

        let results = PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey,
                       draft: PrepDraft(subject: "A cold pitch", body: "Hello, I photograph...", variant: "A"))
        ])
        let outcome = PrepImporter.ingest(results, into: ctx)

        #expect(p.draftSubject == "Your November dates")
        #expect(p.draftBody == "Hi Olga, are the November dates set yet?")
        #expect(p.draftModel == nil)
        #expect(outcome.skippedHandWritten == 1)
        #expect(outcome.skippedEdited == 0)
        #expect(outcome.drafted == 0)
    }

    // The draft lint is a quality gate, not an AI gate. The manual path is a shortcut around the model,
    // never around the check, so text Dan typed himself is blocked by exactly what an AI draft is.
    @Test func theLintBlocksHandWrittenTextTheSameWayItBlocksAnAiDraft() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "Photos are at https://example.com/gallery, let me know.")
        let r = Recipient(id: "olga@bargemusic.org", email: "olga@bargemusic.org", provenance: .manual)
        p.addRecipient(r)

        #expect(r.draftLintBlockers.contains(.foreignLink))
        #expect(r.isBlockedByDraftLint)
        #expect(r.isSendablePending == false)
    }
}
