import Testing
import Foundation
import SwiftData
@testable import Overture

// #891: when a source keeps coming back with shows Overture could not read, Dan is told.
//
// The extract run WebFetches each event's own detail page for the venue. An event whose page it never
// reached comes back with no venue and is DROPPED. The app has always known this was happening, and the
// count went nowhere but the lead sheet.
//
// It matters more since #887, which now READS that count: a source that loses more than
// maxRejectedFraction of its shows silently forfeits the right to mark anything cancelled. That is the
// safe behaviour, but a capability switching itself off with no symptom is the "rule that silently never
// fires" problem (#888), and Dan must be able to see it.
//
// The sentence he reads is computed HERE, from the same rule the reconcile used, and not inside the view.
// Two reasons: a rule computed in a view is unreachable by any test (#863, #885), and a display that
// re-derives the tolerance independently would eventually disagree with the reconcile, telling him
// cancellation is fine on a source where it is switched off.
@Suite("Telling Dan a source's shows could not be read (#891)")
struct SourceReadabilityTests {

    // A source that read everything, at its usual size, says nothing. Silence must mean healthy, or the
    // line is noise.
    @Test func aSourceThatReadEveryShowSaysNothing() {
        #expect(SourceReadability.note(readable: 40, unreadable: 0, baseline: 40) == nil)
    }

    // A stray unreadable listing is worth stating, but it has NOT cost the source anything: it is inside
    // the tolerance, so cancellation still works. The copy must not imply otherwise.
    @Test func aStrayUnreadableShowIsMentionedWithoutAlarm() {
        let note = SourceReadability.note(readable: 39, unreadable: 1, baseline: 40)

        #expect(note == "1 of 40 shows had no venue on their own detail page.")
    }

    // THE case. Past the tolerance, this source can no longer mark anything cancelled, and saying only
    // "12 shows had no venue" would hide the consequence, which is the part Dan can act on.
    @Test func aSourceThatLostTooManyShowsSaysWhatThatCostIt() {
        let note = SourceReadability.note(readable: 68, unreadable: 12, baseline: 80)

        #expect(note == "12 of 80 shows had no venue on their own detail page, so Overture won't mark anything from this source as gone until it can confirm one.")
    }

    // #897: the OTHER way a source loses its cancelling, and it must be as visible as the first. This run
    // read everything it found and simply found half a calendar, which is what a page that half loads looks
    // like. Overture will not believe it until it holds, and a capability switching itself off with no
    // symptom is the exact bug (#888) this line exists to prevent.
    @Test func aSourceThatCameBackHalfSizeSaysWhatThatCostIt() {
        let note = SourceReadability.note(readable: 16, unreadable: 0, baseline: 30)

        #expect(note == "16 shows listed, down from the usual 30, so Overture won't mark anything from this source as gone until the smaller calendar holds.")
    }

    // A calendar that lost a show or two is normal, still credible, and still cancels. No line.
    @Test func aNormalSizedCalendarSaysNothing() {
        #expect(SourceReadability.note(readable: 29, unreadable: 0, baseline: 30) == nil)
    }

    // A source growing is never suspicious, and must never be reported as if it were.
    @Test func aGrowingCalendarSaysNothing() {
        #expect(SourceReadability.note(readable: 45, unreadable: 0, baseline: 30) == nil)
    }

    // Both at once: unread pages ALSO shrink the feed count, so a heavily unread run trips both rules. The
    // unread pages are the CAUSE, so that is what Dan is told; naming the shrink would describe a symptom
    // and hide the thing he can act on.
    @Test func whenBothAreTrueTheUnreadPagesAreNamedBecauseTheyAreTheCause() {
        let note = SourceReadability.note(readable: 10, unreadable: 20, baseline: 30)

        #expect(note?.contains("no venue on their own detail page") == true)
        #expect(note?.contains("down from the usual") == false)
    }

    // The line the display draws MUST be the line the reconcile drew. If these two ever disagree, Dan is
    // told cancellation is working on a source where it is switched off, which is worse than saying
    // nothing at all. Same function, not a second copy of the rule.
    @Test func theDisplayAgreesWithTheReconcileAboutUnreadPages() {
        for unreadable in 0...20 {
            let readable = 80 - unreadable
            let reconcileWillCancel = FeedReconcile.rejectedIsWithinTolerance(
                readable: readable, unreadable: unreadable)
            let noteSaysItWont = SourceReadability.note(readable: readable, unreadable: unreadable,
                                                        baseline: 80)?
                .contains("won't mark anything") ?? false

            #expect(reconcileWillCancel != noteSaysItWont,
                    "readable \(readable), unreadable \(unreadable): the sheet and the reconcile disagree")
        }
    }

    // #897: the same agreement, on the size rule, checked against the reconcile's REAL verdict rather than
    // against a re-derivation of the rule. A sheet that quietly drifts from absenceIsEvidence is the one
    // failure this whole file exists to prevent.
    @Test func theDisplayAgreesWithTheReconcileAboutAShrunkenFeed() {
        for readable in 1...45 {
            let report = FeedReconcile.SourceReport(
                sourceId: "kaufman", seenKeys: [], seenSourceURLs: [],
                feedCount: readable, baseline: 30,
                successfulCheckCount: WatchedSource.warmupRuns,
                verdict: .upcomingListings, rejectedCount: 0)
            let noteSaysItWont = SourceReadability.note(readable: readable, unreadable: 0, baseline: 30)?
                .contains("won't mark anything") ?? false

            #expect(report.absenceIsEvidence != noteSaysItWont,
                    "a feed of \(readable) against a baseline of 30: the sheet and the reconcile disagree")
        }
    }

    // A run that read NOTHING is a broken run, and it never gets the tolerance (#887).
    @Test func aRunThatReadNothingSaysSo() {
        let note = SourceReadability.note(readable: 0, unreadable: 6, baseline: 30)

        #expect(note?.contains("won't mark anything") == true)
    }

    // An EMPTY feed is deliberately not the shrink case. A source with nothing upcoming is in a quiet
    // off-season or is plain broken, and its health and its own run note already say so. Reporting it here
    // as a shrunken calendar would put a permanent alarming line on every off-season source all summer.
    @Test func anEmptyFeedIsNotReportedAsAShrunkenCalendar() {
        #expect(SourceReadability.note(readable: 0, unreadable: 0, baseline: 30) == nil)
    }

    // MARK: - #1032: a titleless drop is not a "no venue" drop.

    // A row with no name is dropped, but no detail page would fix it, so it must not be lumped into the
    // "no venue on their own detail page" sentence. Past the tolerance, both families are named.
    @Test func aTitlelessDropIsNamedSeparatelyFromVenueDropsPastTolerance() {
        let note = SourceReadability.note(readable: 68, unreadable: 12, titleRejected: 2, baseline: 80)

        #expect(note == "10 of 80 shows had no venue on their own detail page and 2 had no title, so Overture won't mark anything from this source as gone until it can read its pages again.")
    }

    // When EVERY drop is titleless, the note never says "no venue" at all: nothing here is about a venue.
    @Test func aRunWhoseOnlyDropsAreTitlelessNeverSaysNoVenue() {
        let note = SourceReadability.note(readable: 68, unreadable: 12, titleRejected: 12, baseline: 80)

        #expect(note == "12 of 80 shows had no title, so Overture won't mark anything from this source as gone until it can read its pages again.")
        #expect(note?.contains("no venue") == false)
    }

    // Inside the tolerance, the same split, without the cancellation consequence.
    @Test func aTitlelessDropInsideToleranceIsNamedWithoutAlarm() {
        let note = SourceReadability.note(readable: 78, unreadable: 2, titleRejected: 1, baseline: 80)

        #expect(note == "1 of 80 shows had no venue on their own detail page and 1 had no title.")
    }

    // The common case (no titleless drops) is byte-identical to before this split existed: a run whose
    // drops are all venue-related reads exactly as it always has, whether the param is omitted or 0.
    @Test func theVenueOnlyCopyIsUnchangedByTheSplit() {
        #expect(SourceReadability.note(readable: 68, unreadable: 12, titleRejected: 0, baseline: 80)
            == SourceReadability.note(readable: 68, unreadable: 12, baseline: 80))
        #expect(SourceReadability.note(readable: 39, unreadable: 1, titleRejected: 0, baseline: 40)
            == "1 of 40 shows had no venue on their own detail page.")
    }
}

// The count has to survive the run that produced it, or the Sources sheet could only ever show it in the
// seconds after a scout, which is exactly when Dan is not looking at the Sources sheet.
@MainActor
@Suite("A source remembers what it could not read (#891)")
struct SourceReadabilityPersistenceTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func source(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                              listingsURL: "https://kaufman.example/calendar", kind: .html)
        s.pendingContentHash = "new-hash"
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    private func event(_ title: String, venue: String?) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: venue,
                          performanceDate: "2099-10-01",
                          sourceUrl: "https://kaufman.example/\(title)")
    }

    private func ingest(_ events: [ScoutExtractEvent], into ctx: ModelContext) {
        let r = ScoutExtractResults(
            version: 1, generatedAt: "2026-07-13T00:00:00Z",
            results: [ScoutExtractResult(sourceId: "kaufman", verdict: .upcomingListings,
                                         events: events, note: nil)])
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures,
                                  now: Date(timeIntervalSince1970: 1_800_000_000), into: ctx)
    }

    @Test func anIngestRecordsWhatItCouldNotRead() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Read", venue: "Merkin Hall"),
                event("Unread", venue: nil)], into: ctx)

        #expect(s.lastReadableCount == 1)
        #expect(s.lastUnreadableCount == 1)
        #expect(s.lastUnreadableTitleCount == 0)                              // the drop was a venue drop
        #expect(s.readabilityNote?.contains("won't mark anything") == true)   // 50%, far past tolerance
    }

    // #1032: a row with a venue but no NAME is dropped and recorded as a title drop, apart from the venue
    // drops, so the source's own note names it correctly ("no title") instead of "no venue on their own
    // detail page" (which no detail page would ever fix). Through the REAL ingest, so the wire that carries
    // the split to Dan is exercised, not only the pure note.
    @Test func anIngestRecordsATitlelessDropSeparately() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Read", venue: "Merkin Hall"),
                event("", venue: "Merkin Hall")], into: ctx)   // a real venue, but no name at all

        #expect(s.lastReadableCount == 1)
        #expect(s.lastUnreadableCount == 1)
        #expect(s.lastUnreadableTitleCount == 1)
        #expect(s.readabilityNote?.contains("no title") == true)
        #expect(s.readabilityNote?.contains("no venue") == false)
    }

    // #897, through the REAL ingest, because the rule and the WIRE that carries it to Dan are two separate
    // claims and only one of them was ever tested. SourceReadability.note could be perfect and
    // WatchedSource.readabilityNote could pass it a baseline of zero, and every other test in this file
    // would still pass while the sheet said nothing at all. That exact cut has gone unnoticed here before
    // (#887's guard, green across 1,829 tests).
    //
    // So: a real source that usually lists 30 shows reads its page, gets 16, and Dan is told, in the row he
    // will actually look at, that it cannot mark anything gone until that smaller calendar holds.
    @Test func aRunThatCameBackHalfSizeSaysSoOnTheSourceItself() throws {
        let ctx = try context()
        let s = source(ctx)
        s.baselineFeedCount = 30
        s.successfulCheckCount = WatchedSource.warmupRuns

        ingest((1...16).map { event("Show \($0)", venue: "Merkin Hall") }, into: ctx)

        #expect(s.lastReadableCount == 16)
        #expect(s.baselineFeedCount == 30)          // NOT re-baselined to 16: the shrink is not believed yet
        #expect(s.readabilityNote == "16 shows listed, down from the usual 30, so Overture won't mark anything from this source as gone until the smaller calendar holds.")
    }

    // ...and it stops saying it the moment the smaller calendar is believed, or the line becomes permanent
    // furniture on a source that is working perfectly well at its new size.
    @Test func aShrunkenSourceStopsComplainingOnceItsNewSizeIsBelieved() throws {
        let ctx = try context()
        let s = source(ctx)
        s.baselineFeedCount = 30
        s.successfulCheckCount = WatchedSource.warmupRuns

        for read in 0..<FeedReconcile.selfHealThreshold {
            s.pendingContentHash = "hash-\(read)"   // its page changed again, and again it lists 16
            s.hasUnreadChanges = true
            ingest((1...16).map { event("Show \($0)", venue: "Merkin Hall") }, into: ctx)
        }

        #expect(s.baselineFeedCount == 16)          // the shrink held, so 16 is simply what this source is
        #expect(s.readabilityNote == nil)
    }

    // A source that recovers must STOP saying it is broken, or the warning becomes permanent furniture and
    // Dan learns to skim past the one line he must never skim past.
    @Test func aSourceThatRecoversStopsComplaining() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Read", venue: "Merkin Hall"), event("Unread", venue: nil)], into: ctx)
        #expect(s.readabilityNote != nil)

        s.pendingContentHash = "newer-hash"      // its page changed again and this run read all of it
        ingest([event("Read", venue: "Merkin Hall"), event("Unread", venue: "Merkin Hall")], into: ctx)

        #expect(s.lastUnreadableCount == 0)
        #expect(s.readabilityNote == nil)
    }
}
