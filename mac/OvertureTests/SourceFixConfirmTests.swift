import Testing
import Foundation
import SwiftData
@testable import Overture

// #1027 Phase 1: the model field and the two failure predicates the fix/confirm popup rests on.
//
// CONFIRM ("this page is right, stop nagging") is offered on exactly one failure: a page that fetched
// and read fine but had no dated listings. FIX (correct the URL) is offered on anything a wrong address
// could explain, which is everything EXCEPT the two failures no URL change can fix: a run that ended
// before opening the page (it self-heals next run) and a run that contradicted itself (a run bug).
@MainActor
@Suite("Source fix/confirm predicates and the confirmed-empty hash (#1027)")
struct SourceFixConfirmTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @Test func confirmedEmptyHashDefaultsNilAndRoundTrips() throws {
        let ctx = try context()
        let source = WatchedSource(sourceId: "kaufman", orgName: "Kaufman", kind: .html)
        #expect(source.confirmedEmptyHash == nil)      // a new source has confirmed nothing
        source.confirmedEmptyHash = "abc123"
        ctx.insert(source)
        try ctx.save()

        let stored = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first)
        #expect(stored.confirmedEmptyHash == "abc123")
    }

    // CONFIRM is offered for a page that read fine but is empty, and for NOTHING else: confirming a
    // broken fetch or an unreadable JS page would silence a source that never delivers.
    @Test func onlyNoDatedContentOffersConfirm() {
        #expect(SourceFailure.verdict(.noDatedContent).offersConfirm)
        #expect(!SourceFailure.verdict(.unreadable).offersConfirm)
        #expect(!SourceFailure.verdict(.notRead).offersConfirm)
        #expect(!SourceFailure.inconsistentResult.offersConfirm)
        #expect(!SourceFailure.fetch(.http(404)).offersConfirm)
        #expect(!SourceFailure.fetch(.unreachable).offersConfirm)
    }

    // FIX is offered wherever a corrected address could plausibly be the answer, and withheld from the
    // two failures no address change can fix.
    @Test func fixOfferedExceptForSelfHealingAndRunBugFailures() {
        #expect(SourceFailure.verdict(.noDatedContent).offersFix)
        #expect(SourceFailure.verdict(.unreadable).offersFix)
        #expect(SourceFailure.fetch(.http(404)).offersFix)
        #expect(SourceFailure.fetch(.redirectedAway("elsewhere.org")).offersFix)
        #expect(SourceFailure.fetch(.unreachable).offersFix)
        #expect(!SourceFailure.verdict(.notRead).offersFix)         // self-heals next run
        #expect(!SourceFailure.inconsistentResult.offersFix)        // a run bug, not a bad address
    }

    // The suppression test: a confirmed no_dated_content page whose just-read bytes still match the
    // confirmed hash is quiet; a different hash (the page changed) or a nil hash is NOT.
    @Test func confirmedQuietOnlyWhenNoDatedContentHashMatches() {
        #expect(SourceConfirmation.isConfirmedQuiet(
            verdict: .noDatedContent, readHash: "H1", confirmedEmptyHash: "H1"))
        // page changed since Dan confirmed: nag again
        #expect(!SourceConfirmation.isConfirmedQuiet(
            verdict: .noDatedContent, readHash: "H2", confirmedEmptyHash: "H1"))
        // nothing confirmed yet
        #expect(!SourceConfirmation.isConfirmedQuiet(
            verdict: .noDatedContent, readHash: "H1", confirmedEmptyHash: nil))
        // no read hash to compare
        #expect(!SourceConfirmation.isConfirmedQuiet(
            verdict: .noDatedContent, readHash: nil, confirmedEmptyHash: "H1"))
        // a matching hash on a DIFFERENT verdict is not a confirmed-quiet page
        #expect(!SourceConfirmation.isConfirmedQuiet(
            verdict: .unreadable, readHash: "H1", confirmedEmptyHash: "H1"))
    }
}
