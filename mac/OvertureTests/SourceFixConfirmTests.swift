import Testing
import Foundation
import SwiftData

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

    // #1048: the page hash the most recent fetch actually SAW, ingested or not, defaults nil and round
    // trips. It is the "current live page as far as we know", distinct from the last INGESTED hash and
    // the last READ-and-pinned hash.
    @Test func lastObservedContentHashDefaultsNilAndRoundTrips() throws {
        let ctx = try context()
        let source = WatchedSource(sourceId: "kaufman", orgName: "Kaufman", kind: .html)
        #expect(source.lastObservedContentHash == nil)     // nothing fetched yet
        source.lastObservedContentHash = "seen1"
        ctx.insert(source)
        try ctx.save()

        let stored = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first)
        #expect(stored.lastObservedContentHash == "seen1")
    }

    // #1048: the staleness predicate the Sources confirm affordance rests on. A confirm anchors to the
    // bytes last READ (pendingContentHash, or the last ingested hash). If the live page has moved on
    // since, a watch-only pass records the new hash and the anchor no longer matches what the next real
    // read will see, so the confirmation cannot stick. Pure, so the warning is a tested rule and not
    // logic buried in the view (#863).
    @Test func readIsStaleForConfirmOnlyWhenTheSeenHashHasMovedPastTheAnchor() {
        // fresh: the bytes we would anchor to are the bytes we last saw. The confirm will stick.
        #expect(!SourceConfirmation.readIsStaleForConfirm(anchorHash: "A", lastSeenHash: "A"))
        // stale: a watch-only pass saw new bytes after the read. Confirming now would anchor to the old
        // bytes and the next read would not match, so it would silently fail to suppress.
        #expect(SourceConfirmation.readIsStaleForConfirm(anchorHash: "A", lastSeenHash: "B"))
        // nothing read to anchor to: not stale (confirmEmpty returns .noHash on its own).
        #expect(!SourceConfirmation.readIsStaleForConfirm(anchorHash: nil, lastSeenHash: "B"))
        // never observed a live hash (a legacy row from before this field): do not over-warn.
        #expect(!SourceConfirmation.readIsStaleForConfirm(anchorHash: "A", lastSeenHash: nil))
    }

    // #1048: the row's own read of that predicate. A source whose pinned read bytes still match the last
    // seen bytes is fresh; one the watch-only pass has since seen change is stale.
    @Test func confirmReadIsStaleReflectsPendingVersusLastObserved() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "org", orgName: "Org", listingsURL: "https://org.example/e", kind: .html)

        // Just read: the pinned bytes are the bytes we last saw.
        s.pendingContentHash = "A"
        s.lastObservedContentHash = "A"
        #expect(!s.confirmReadIsStale)

        // A later watch-only pass saw the page change. The pinned read is now stale.
        s.lastObservedContentHash = "B"
        #expect(s.confirmReadIsStale)

        // With no pinned read, the anchor falls back to the last ingested hash.
        s.pendingContentHash = nil
        s.lastContentHash = "A"
        #expect(s.confirmReadIsStale)                       // ingested "A", live page now "B"
        ctx.insert(s); try ctx.save()
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

// #2263: the control is named after what it EDITS.
//
// Seen on the rendered Sources row on 2026-08-07: one row carried "Add address", which sets the street
// address so the source's shows get placed in Dan's area, and four lines below it "Fix the address",
// which edits the web page Overture reads. Two buttons, near-identical names, unrelated jobs, and the
// likely misread was the expensive direction.
//
// #1177 offers this control on EVERY editable row, including a healthy one, so the old name also
// asserted a diagnosis on rows where nothing had failed. Dan settled the other reading of the same
// complaint on 2026-08-07 (#1588): the button stays, because a healthy source pointed at the wrong page
// needs the escape hatch. So the fix is the name.
@Suite("The page link control is named after what it edits (#2263)")
struct PageLinkControlNameTests {

    @Test func itNamesThePageRatherThanAnAddress() {
        #expect(SourceFixConfirmCopy.fixTitle == "Change the page link")
    }

    // The word it may not use, because the control four lines above it on the same row owns it for the
    // street address that places this source's shows.
    @Test func neitherTheLabelNorItsTooltipSaysAddress() {
        #expect(!SourceFixConfirmCopy.fixTitle.lowercased().contains("address"))
        #expect(!SourceFixConfirmCopy.fixHelp.lowercased().contains("address"))
    }

    // And it no longer claims something is wrong, on a row where it is offered whether or not anything
    // failed.
    @Test func itDoesNotAssertADiagnosisItHasNotMade() {
        #expect(!SourceFixConfirmCopy.fixTitle.lowercased().contains("fix"))
    }
}

