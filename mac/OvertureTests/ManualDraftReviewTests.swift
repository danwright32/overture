import Testing
import Foundation

// #2007: what the Review card says about a draft Dan wrote himself.
//
// The whole reason the marker is its own field is that reporting has to tell an email he WROTE from an
// AI draft he TWEAKED. Review is where he reads that distinction first, so it has to be visible there.
@MainActor
@Suite("Reviewing a hand-written draft (#2007)")
struct ManualDraftReviewTests {
    private func prospect() -> Prospect {
        Prospect(naturalKey: "k", groupName: "Bargemusic", discipline: "classical", venue: "Boathouse",
                 performanceDate: "2026-11-14", sourceListingURL: nil,
                 priorRelationship: "booked", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
    }

    @Test func aHandWrittenDraftSaysHeWroteIt() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")

        #expect(QueueItem(p).draftAuthorLabel == "Written by you")
    }

    @Test func anAiDraftStillNamesTheModelThatWroteIt() {
        let p = prospect()
        p.draftBody = "b"
        p.draftModel = "opus"

        #expect(QueueItem(p).draftAuthorLabel == "Drafted by opus")
    }

    @Test func aDraftWithNoRecordOfItsAuthorClaimsNothing() {
        let p = prospect()
        p.draftBody = "b"

        #expect(QueueItem(p).draftAuthorLabel == nil)
    }

    // #879 put the trace on the row so it survives into the archive, where outcomes are compared across
    // models. A show Dan wrote himself must not read there as a model's work.
    @Test func anArchivedHandWrittenShowStillSaysHeWroteIt() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")
        p.draftBody = nil   // archived: the review panel is gone, so the row badge is the only trace left

        #expect(QueueItem(p).rowDraftTraceLabel == "Written by you")
    }

    // The advisory voice findings exist to catch the drafter's AI-tells. Once the words are Dan's the
    // voice is his, which is the suppression an EDITED draft already gets; a draft he wrote from scratch
    // is his more completely, not less.
    @Test func theVoiceFlagsStandDownOnTextHeWroteHimself() {
        #expect(DraftReviewNotes.showsVoiceFindings(editedByDan: false, writtenByDan: true) == false)
        #expect(DraftReviewNotes.showsVoiceFindings(editedByDan: true, writtenByDan: false) == false)
        #expect(DraftReviewNotes.showsVoiceFindings(editedByDan: false, writtenByDan: false))
    }
}
